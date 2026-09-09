import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSAny? property(JSObject object, String name) =>
    object.getProperty<JSAny?>(name.toJS);
JSAny? call(
  JSObject object,
  String name, [
  List<JSAny?> arguments = const [],
]) => object.callMethodVarArgs<JSAny?>(name.toJS, arguments);
Future<JSAny?> invoke(
  JSObject object,
  String name, [
  List<JSAny?> arguments = const [],
]) => (call(object, name, arguments) as JSPromise<JSAny?>).toDart;
JSObject object(Map<String, JSAny?> properties) {
  final result = JSObject();
  for (final entry in properties.entries) {
    result.setProperty(entry.key.toJS, entry.value);
  }
  return result;
}

int integer(JSAny? value) => (value as JSNumber).toDartInt;
String string(JSAny? value) => (value as JSString).toDart;
bool boolean(JSAny? value) => value != null && (value as JSBoolean).toDart;
List<JSObject> objects(JSAny? value) => (value as JSArray<JSObject>).toDart;
Future<void> ignoreFailure(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {}
}
