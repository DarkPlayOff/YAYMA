import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';


enum AppSection {
  home,
  search,
  liked,
  playlists,
  album,
  artist,
  wave,
  playlist,
  account,
  yandexId,
}

@immutable
class NavState {
  final AppSection section;
  final String? id;

  const NavState(this.section, [this.id]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavState &&
          runtimeType == other.runtimeType &&
          section == other.section &&
          id == other.id;

  @override
  int get hashCode => section.hashCode ^ (id?.hashCode ?? 0);
}

/// List of root sections (tabs)
const List<AppSection> rootSections = [
  AppSection.home,
  AppSection.search,
  AppSection.liked,
  AppSection.playlists,
  AppSection.account,
];

/// Currently active root tab
final FlutterSignal<AppSection> currentRootSignal = signal<AppSection>(
  AppSection.home,
);

/// Navigation stacks for each tab
final FlutterSignal<Map<AppSection, List<NavState>>> rootStacksSignal =
    signal<Map<AppSection, List<NavState>>>({
      for (var root in rootSections) root: [NavState(root)],
    });

/// Navbar auto-hide setting
final FlutterSignal<bool> autoHideNavbarSignal = signal<bool>(
  true,
);

/// Custom titlebar setting
final FlutterSignal<bool> customTitlebarSignal = signal<bool>(
  true,
);

/// Computed current navigation stack
final FlutterComputed<List<NavState>> navStackSignal = computed(
  () =>
      rootStacksSignal()[currentRootSignal()] ??
      [NavState(currentRootSignal())],
  debugLabel: 'navStackSignal',
);

/// Back button availability signal
final FlutterComputed<bool> canGoBackSignal = computed(
  () => navStackSignal().length > 1,
  debugLabel: 'canGoBackSignal',
);

/// Top of the active tab stack
final FlutterComputed<NavState> currentNavStateSignal = computed(
  () => navStackSignal().last,
  debugLabel: 'currentNavStateSignal',
);

/// Navigates to a new page
void navigateTo(AppSection section, [String? id]) {
  final newState = NavState(section, id);
  final activeRoot = currentRootSignal.value;

  // Handle root section clicks
  if (rootSections.contains(section) && id == null) {
    if (activeRoot == section) {
      // Reset stack to root if already active
      final newStacks = Map<AppSection, List<NavState>>.from(
        rootStacksSignal.value,
      );
      newStacks[section] = [NavState(section)];
      rootStacksSignal.value = newStacks;
    } else {
      currentRootSignal.value = section;
    }
    return;
  }

  // Regular push transition
  final currentStack =
      rootStacksSignal.value[activeRoot] ?? [NavState(activeRoot)];
  if (currentStack.last == newState) return;

  final newStacks = Map<AppSection, List<NavState>>.from(
    rootStacksSignal.value,
  );
  newStacks[activeRoot] = List.unmodifiable([...currentStack, newState]);
  rootStacksSignal.value = newStacks;
}

/// Returns to the previous page (Pop)
void goBack() {
  final activeRoot = currentRootSignal.value;
  final currentStack = rootStacksSignal.value[activeRoot] ?? [];
  if (currentStack.length <= 1) return;

  final newStacks = Map<AppSection, List<NavState>>.from(
    rootStacksSignal.value,
  );
  newStacks[activeRoot] = List.unmodifiable(
    currentStack.sublist(0, currentStack.length - 1),
  );
  rootStacksSignal.value = newStacks;
}

void setSection(AppSection section) => navigateTo(section);
