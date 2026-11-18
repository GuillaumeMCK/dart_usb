// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'enumeration.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$HotplugEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is HotplugEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'HotplugEvent()';
}


}

/// @nodoc
class $HotplugEventCopyWith<$Res>  {
$HotplugEventCopyWith(HotplugEvent _, $Res Function(HotplugEvent) __);
}


/// Adds pattern-matching-related methods to [HotplugEvent].
extension HotplugEventPatterns on HotplugEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( HotplugEvent_Connected value)?  connected,TResult Function( HotplugEvent_Disconnected value)?  disconnected,required TResult orElse(),}){
final _that = this;
switch (_that) {
case HotplugEvent_Connected() when connected != null:
return connected(_that);case HotplugEvent_Disconnected() when disconnected != null:
return disconnected(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( HotplugEvent_Connected value)  connected,required TResult Function( HotplugEvent_Disconnected value)  disconnected,}){
final _that = this;
switch (_that) {
case HotplugEvent_Connected():
return connected(_that);case HotplugEvent_Disconnected():
return disconnected(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( HotplugEvent_Connected value)?  connected,TResult? Function( HotplugEvent_Disconnected value)?  disconnected,}){
final _that = this;
switch (_that) {
case HotplugEvent_Connected() when connected != null:
return connected(_that);case HotplugEvent_Disconnected() when disconnected != null:
return disconnected(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( DeviceInfo device)?  connected,TResult Function( DeviceId id)?  disconnected,required TResult orElse(),}) {final _that = this;
switch (_that) {
case HotplugEvent_Connected() when connected != null:
return connected(_that.device);case HotplugEvent_Disconnected() when disconnected != null:
return disconnected(_that.id);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( DeviceInfo device)  connected,required TResult Function( DeviceId id)  disconnected,}) {final _that = this;
switch (_that) {
case HotplugEvent_Connected():
return connected(_that.device);case HotplugEvent_Disconnected():
return disconnected(_that.id);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( DeviceInfo device)?  connected,TResult? Function( DeviceId id)?  disconnected,}) {final _that = this;
switch (_that) {
case HotplugEvent_Connected() when connected != null:
return connected(_that.device);case HotplugEvent_Disconnected() when disconnected != null:
return disconnected(_that.id);case _:
  return null;

}
}

}

/// @nodoc


class HotplugEvent_Connected extends HotplugEvent {
  const HotplugEvent_Connected({required this.device}): super._();
  

 final  DeviceInfo device;

/// Create a copy of HotplugEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HotplugEvent_ConnectedCopyWith<HotplugEvent_Connected> get copyWith => _$HotplugEvent_ConnectedCopyWithImpl<HotplugEvent_Connected>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is HotplugEvent_Connected&&(identical(other.device, device) || other.device == device));
}


@override
int get hashCode {
    return Object.hash(runtimeType,device);
}

@override
String toString() {
    return 'HotplugEvent.connected(device: $device)';
}


}

/// @nodoc
abstract mixin class $HotplugEvent_ConnectedCopyWith<$Res> implements $HotplugEventCopyWith<$Res> {
  factory $HotplugEvent_ConnectedCopyWith(HotplugEvent_Connected value, $Res Function(HotplugEvent_Connected) _then) = _$HotplugEvent_ConnectedCopyWithImpl;
@useResult
$Res call({
 DeviceInfo device
});




}
/// @nodoc
class _$HotplugEvent_ConnectedCopyWithImpl<$Res>
    implements $HotplugEvent_ConnectedCopyWith<$Res> {
  _$HotplugEvent_ConnectedCopyWithImpl(this._self, this._then);

  final HotplugEvent_Connected _self;
  final $Res Function(HotplugEvent_Connected) _then;

/// Create a copy of HotplugEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? device = null,}) {
  return _then(HotplugEvent_Connected(
device: null == device ? _self.device : device // ignore: cast_nullable_to_non_nullable
as DeviceInfo,
  ));
}


}

/// @nodoc


class HotplugEvent_Disconnected extends HotplugEvent {
  const HotplugEvent_Disconnected({required this.id}): super._();
  

 final  DeviceId id;

/// Create a copy of HotplugEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$HotplugEvent_DisconnectedCopyWith<HotplugEvent_Disconnected> get copyWith => _$HotplugEvent_DisconnectedCopyWithImpl<HotplugEvent_Disconnected>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is HotplugEvent_Disconnected&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id);
}

@override
String toString() {
    return 'HotplugEvent.disconnected(id: $id)';
}


}

/// @nodoc
abstract mixin class $HotplugEvent_DisconnectedCopyWith<$Res> implements $HotplugEventCopyWith<$Res> {
  factory $HotplugEvent_DisconnectedCopyWith(HotplugEvent_Disconnected value, $Res Function(HotplugEvent_Disconnected) _then) = _$HotplugEvent_DisconnectedCopyWithImpl;
@useResult
$Res call({
 DeviceId id
});




}
/// @nodoc
class _$HotplugEvent_DisconnectedCopyWithImpl<$Res>
    implements $HotplugEvent_DisconnectedCopyWith<$Res> {
  _$HotplugEvent_DisconnectedCopyWithImpl(this._self, this._then);

  final HotplugEvent_Disconnected _self;
  final $Res Function(HotplugEvent_Disconnected) _then;

/// Create a copy of HotplugEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,}) {
  return _then(HotplugEvent_Disconnected(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as DeviceId,
  ));
}


}

// dart format on
