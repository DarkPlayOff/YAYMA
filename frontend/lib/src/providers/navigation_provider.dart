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

/// Список "корневых" разделов (вкладок)
const List<AppSection> rootSections = [
  AppSection.home,
  AppSection.search,
  AppSection.liked,
  AppSection.playlists,
  AppSection.account,
];

/// Текущая активная корневая вкладка
final FlutterSignal<AppSection> currentRootSignal = signal<AppSection>(
  AppSection.home,
);

/// Стэки навигации для каждой вкладки
final FlutterSignal<Map<AppSection, List<NavState>>> rootStacksSignal =
    signal<Map<AppSection, List<NavState>>>({
      for (var root in rootSections) root: [NavState(root)],
    });

/// Вычисляемый текущий стек
final FlutterComputed<List<NavState>> navStackSignal = computed(
  () =>
      rootStacksSignal()[currentRootSignal()] ??
      [NavState(currentRootSignal())],
  debugLabel: 'navStackSignal',
);

/// Сигнал доступности кнопки "Назад"
final FlutterComputed<bool> canGoBackSignal = computed(
  () => navStackSignal().length > 1,
  debugLabel: 'canGoBackSignal',
);

/// Текущее состояние (верхушка стека активной вкладки)
final FlutterComputed<NavState> currentNavStateSignal = computed(
  () => navStackSignal().last,
  debugLabel: 'currentNavStateSignal',
);

/// Переход на новую страницу
void navigateTo(AppSection section, [String? id]) {
  final newState = NavState(section, id);
  final activeRoot = currentRootSignal.value;

  // Если мы кликаем на корневой раздел (например, в сайдбаре)
  if (rootSections.contains(section) && id == null) {
    if (activeRoot == section) {
      // Если кликнули на уже активную вкладку - сбрасываем её стек к корню
      final newStacks = Map<AppSection, List<NavState>>.from(
        rootStacksSignal.value,
      );
      newStacks[section] = [NavState(section)];
      rootStacksSignal.value = newStacks;
    } else {
      // Иначе просто переключаем вкладку
      currentRootSignal.value = section;
    }
    return;
  }

  // Обычный переход (Push) в текущей вкладке
  final currentStack =
      rootStacksSignal.value[activeRoot] ?? [NavState(activeRoot)];
  if (currentStack.last == newState) return;

  final newStacks = Map<AppSection, List<NavState>>.from(
    rootStacksSignal.value,
  );
  newStacks[activeRoot] = List.unmodifiable([...currentStack, newState]);
  rootStacksSignal.value = newStacks;
}

/// Возврат на предыдущую страницу (Pop)
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
