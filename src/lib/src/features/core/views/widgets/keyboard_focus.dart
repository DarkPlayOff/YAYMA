import 'package:flutter/widgets.dart';

/// Drops text-field focus when the pointer goes down outside the field.
///
/// Flutter mirrors native Android and keeps the field focused on a touch
/// outside, so the keyboard returns on the next focus event — e.g. after the
/// player, opened from the search results, is dismissed.
final Map<Type, Action<Intent>> unfocusOnTapOutside = <Type, Action<Intent>>{
  EditableTextTapOutsideIntent: CallbackAction<EditableTextTapOutsideIntent>(
    onInvoke: (intent) {
      intent.focusNode.unfocus();
      return null;
    },
  ),
};
