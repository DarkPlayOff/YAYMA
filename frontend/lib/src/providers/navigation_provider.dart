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

// Единственный источник истины - стек навигации
final FlutterSignal<List<NavState>> navStackSignal = signal<List<NavState>>([
  const NavState(AppSection.home),
]);

// Сигнал доступности кнопки "Назад"
final FlutterComputed<bool> canGoBackSignal = computed(
  () => navStackSignal().length > 1,
  debugLabel: 'canGoBackSignal',
);

// Текущее состояние (верхушка стека)
final FlutterComputed<NavState> currentNavStateSignal = computed(
  () => navStackSignal().last,
  debugLabel: 'currentNavStateSignal',
);

/// Список "корневых" разделов, которые сбрасывают стек
const Set<AppSection> _rootSections = {
  AppSection.home,
  AppSection.search,
  AppSection.liked,
  AppSection.playlists,
  AppSection.account,
};

/// Переход на новую страницу
void navigateTo(AppSection section, [String? id]) {
  final newState = NavState(section, id);
  final currentStack = navStackSignal.value;

  // Если это корневой раздел без специфичного ID, сбрасываем стек
  if (_rootSections.contains(section) && id == null) {
    if (currentStack.length == 1 && currentStack.first == newState) return;
    navStackSignal.value = List.unmodifiable([newState]);
    return;
  }

  // Не дублируем переход на ту же самую страницу
  if (currentStack.last == newState) return;

  navStackSignal.value = List.unmodifiable([...currentStack, newState]);
}

/// Возврат на предыдущую страницу
void goBack() {
  final currentStack = navStackSignal.value;
  if (currentStack.length <= 1) return;

  navStackSignal.value = List.unmodifiable(
    currentStack.sublist(0, currentStack.length - 1),
  );
}

// Упрощенные методы для UI
void setSection(AppSection section) => navigateTo(section);
