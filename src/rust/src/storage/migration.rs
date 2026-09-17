// ---------------------------------------------------------------------------
// Toasty-era migration. Tables are identified by column signature, not by
// name (toasty auto-pluralizes model names), merged into our schema and
// dropped. Best effort: any failure is logged and ignored so a foreign
// schema can never brick startup.
//
// Runs in two phases around our CREATEs (see `AppDatabase::init`):
//   1. `stash_foreign_tables` renames foreign tables aside so
//      CREATE TABLE IF NOT EXISTS can't silently reuse a wrong schema.
//   2. `merge_foreign_tables` copies stashed rows into the fresh schema
//      and drops the backups — but only after a successful copy, so a
//      failed merge is retried on the next launch instead of losing data.
// ---------------------------------------------------------------------------

use super::db::DEFAULT_CACHE_TTL_SECS;
use rusqlite::Connection;

/// Tables owned by this backend. Anything else with a matching column
/// signature is treated as a leftover from the toasty era and merged in.
const OWN_TABLES: &[&str] = &[
    "app_settings",
    "liked_tracks",
    "cache_metadata",
    "track_metadata",
    "track_metadata_artists",
];

/// Phase 1 (runs BEFORE our CREATEs): rename foreign tables aside so
/// CREATE TABLE IF NOT EXISTS can't silently reuse a wrong schema that
/// happens to share our table name.
pub(crate) fn stash_foreign_tables(conn: &Connection) {
    // A table is kept only if columns AND primary key match ours exactly —
    // a name match alone is not enough (toasty pluralizes model names into
    // the same words, e.g. `cache_metadata`, but with its own constraints).
    let keep: &[(&str, &[&str], &[&str])] = &[
        ("app_settings", &["key", "value"], &["key"]),
        ("liked_tracks", &["track_id"], &["track_id"]),
        (
            "cache_metadata",
            &[
                "url",
                "file_path",
                "size",
                "last_access_at",
                "created_at",
                "expires_at",
                "etag",
            ],
            &["url"],
        ),
        (
            "track_metadata",
            &[
                "track_id",
                "title",
                "version",
                "album",
                "album_id",
                "cover_url",
                "duration_ms",
            ],
            &["track_id"],
        ),
        (
            "track_metadata_artists",
            &["track_id", "artist_id", "name", "position"],
            &["track_id", "position"],
        ),
    ];
    for (table, expected_cols, expected_pk) in keep {
        let tables = list_tables(conn);
        if !tables.iter().any(|t| t == table) {
            continue;
        }
        let info = table_info(conn, table);
        let cols = col_names(&info);
        let pk = pk_cols(&info);
        let same_cols = cols.len() == expected_cols.len() && has_all(&cols, expected_cols);
        if same_cols && pk == *expected_pk {
            continue; // ours (or fully identical) — keep as is.
        }
        if stash_aside(conn, table) {
            tracing::info!("Stashed foreign table {} for migration", table);
        } else {
            tracing::warn!(
                "Failed to stash foreign table {} aside; CREATE may reuse a wrong schema",
                table
            );
        }
    }
}

/// Phase 3 (runs AFTER our CREATEs): merge every foreign table (stashed
/// backups or oddly named toasty tables) by column signature into the
/// fresh schema, then drop it. Own compatible tables are skipped.
/// Best effort: failures are logged, never fatal.
pub(crate) fn merge_foreign_tables(conn: &Connection) {
    let now = chrono::Utc::now().timestamp();
    let ttl = now + DEFAULT_CACHE_TTL_SECS;

    let tables = list_tables(conn);
    for t in &tables {
        if OWN_TABLES.iter().any(|o| o == t) {
            continue;
        }
        let info = table_info(conn, t);
        let cols = col_names(&info);
        let backup = t.clone();

        if cols.len() == 2 && has_all(&cols, &["key", "value"]) {
            if copy_mapped(
                conn,
                &backup,
                "app_settings",
                &[("key", None), ("value", None)],
            ) {
                let _ = conn.execute(&format!("DROP TABLE {}", quote_ident(&backup)), []);
            }
        } else if has_all(&cols, &["url", "file_path"]) {
            if copy_mapped(
                conn,
                &backup,
                "cache_metadata",
                &[
                    ("url", None),
                    ("file_path", Some("''")),
                    ("size", Some("0")),
                    ("last_access_at", Some(&now.to_string())),
                    ("created_at", Some(&now.to_string())),
                    ("expires_at", Some(&ttl.to_string())),
                    ("etag", None),
                ],
            ) {
                let _ = conn.execute(&format!("DROP TABLE {}", quote_ident(&backup)), []);
            }
        } else if cols.contains(&"title") && cols.contains(&"track_id") {
            if copy_mapped(
                conn,
                &backup,
                "track_metadata",
                &[
                    ("track_id", None),
                    ("title", Some("''")),
                    ("version", None),
                    ("album", None),
                    ("album_id", None),
                    ("cover_url", None),
                    ("duration_ms", Some("0")),
                ],
            ) {
                let _ = conn.execute(&format!("DROP TABLE {}", quote_ident(&backup)), []);
            }
        } else if has_all(&cols, &["artist_id", "name", "position"]) {
            // Toasty named the track ref `track_metadata_entity_id`.
            let track_ref = if cols.contains(&"track_id") {
                "track_id"
            } else {
                "track_metadata_entity_id"
            };
            let sql = format!(
                "INSERT OR REPLACE INTO track_metadata_artists (track_id, artist_id, name, position)
                 SELECT {}, artist_id, name, position FROM {}",
                quote_ident(track_ref),
                quote_ident(&backup)
            );
            if cols.contains(&track_ref) {
                match conn.execute(&sql, []) {
                    Ok(_) => {
                        let _ = conn.execute(&format!("DROP TABLE {}", quote_ident(&backup)), []);
                    }
                    Err(e) => {
                        tracing::warn!(
                            "Migration copy {} -> track_metadata_artists failed: {}",
                            backup,
                            e
                        );
                    }
                }
            }
        }
    }
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn list_tables(conn: &Connection) -> Vec<String> {
    conn.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        .and_then(|mut s| {
            s.query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()
        })
        .unwrap_or_default()
}

fn table_info(conn: &Connection, table: &str) -> Vec<(String, i64)> {
    conn.prepare(&format!(
        "SELECT name, pk FROM pragma_table_info({})",
        quote_ident(table)
    ))
    .and_then(|mut s| {
        s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()
    })
    .unwrap_or_default()
}

fn col_names(info: &[(String, i64)]) -> Vec<&str> {
    info.iter().map(|(n, _)| n.as_str()).collect()
}

/// Primary-key columns in key order.
fn pk_cols(info: &[(String, i64)]) -> Vec<&str> {
    let mut v: Vec<(i64, &str)> = info
        .iter()
        .filter(|(_, pk)| *pk > 0)
        .map(|(n, pk)| (*pk, n.as_str()))
        .collect();
    v.sort();
    v.into_iter().map(|(_, n)| n).collect()
}

fn has_all(cols: &[&str], want: &[&str]) -> bool {
    want.iter().all(|w| cols.contains(w))
}

/// Rename a foreign table aside so our CREATE won't silently reuse a wrong schema.
/// If `{table}_backup_toasty` already exists (e.g. two interrupted migrations
/// in a row), fall back to a numbered suffix so the rename never fails
/// silently. `merge_foreign_tables` picks up any non-owned table by column
/// signature, so suffixed backups are still merged on the next phase.
fn stash_aside(conn: &Connection, table: &str) -> bool {
    let existing = list_tables(conn);
    let mut candidate = format!("{}_backup_toasty", table);
    if existing.iter().any(|t| t == &candidate) {
        let mut n = 1;
        while existing.iter().any(|t| t == &candidate) && n < 100 {
            n += 1;
            candidate = format!("{}_backup_toasty_{}", table, n);
        }
        if existing.iter().any(|t| t == &candidate) {
            tracing::warn!(
                "stash_aside: backup slot occupied for {}, cannot rename",
                table
            );
            return false;
        }
        tracing::warn!(
            "stash_aside: {} occupied, using fallback name {}",
            format!("{}_backup_toasty", table),
            candidate
        );
    }
    match conn.execute(
        &format!(
            "ALTER TABLE {} RENAME TO {}",
            quote_ident(table),
            quote_ident(&candidate)
        ),
        [],
    ) {
        Ok(_) => true,
        Err(e) => {
            tracing::warn!("stash_aside: failed to rename {} aside: {}", table, e);
            false
        }
    }
}

/// Copy rows from a backup table, mapping only columns that exist there.
/// Missing columns fall back to the given literal defaults.
/// Returns false (and logs) when nothing could be copied — the caller
/// must keep the backup in that case so a later launch can retry.
fn copy_mapped(
    conn: &Connection,
    backup: &str,
    target: &str,
    mapping: &[(&str, Option<&str>)],
) -> bool {
    let info = table_info(conn, backup);
    let cols = col_names(&info);
    let mut dst = Vec::new();
    let mut src = Vec::new();
    for (col, default) in mapping {
        if cols.contains(col) {
            dst.push(quote_ident(col));
            src.push(quote_ident(col));
        } else if let Some(d) = default {
            dst.push(quote_ident(col));
            src.push(d.to_string());
        }
    }
    if dst.is_empty() {
        return false;
    }
    let sql = format!(
        "INSERT OR REPLACE INTO {} ({}) SELECT {} FROM {}",
        quote_ident(target),
        dst.join(", "),
        src.join(", "),
        quote_ident(backup)
    );
    match conn.execute(&sql, []) {
        Ok(_) => true,
        Err(e) => {
            tracing::warn!("Migration copy {} -> {} failed: {}", backup, target, e);
            false
        }
    }
}
