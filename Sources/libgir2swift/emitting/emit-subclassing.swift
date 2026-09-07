import Foundation

private let asyncAvailability = "@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)"
private let implementationAvailability = "@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)"

/// Emits Swift support for implementing GObject interfaces and subclassing
/// GObject-derived classes. For every interface and derivable class that owns
/// a GType, a `<Name>Implementation` (interfaces) or `<Name>Subclass` (classes)
/// base is generated. A Swift author subclasses it and overrides the virtual
/// methods they care about; the generated machinery registers a GType at
/// runtime, wires the vtable to `@convention(c)` thunks, and forwards each call
/// to the Swift instance stored alongside the GObject.
///
/// Virtual methods whose shape cannot be represented safely are skipped, so the
/// generated code always compiles even where a vtable entry is exotic.
func buildSubclassingCode(for record: GIR.Record) -> String {
    guard record is GIR.Class, let getType = record.typegetter else { return "" }

    let isInterface = record is GIR.Interface
    let baseName = record.name.swift + (isInterface ? "Implementation" : "Subclass")
    let ctype = record.typeRef.type.ctype
    guard !ctype.isEmpty else { return "" }

    let cPrefix = record.name.isEmpty ? "" : (ctype.stringByRemoving(suffix: record.name) ?? "")
    let vtableCType: String? = record.typeStruct.flatMap { $0.isEmpty ? nil : cPrefix + $0 }

    // Subclassing a class requires access to its class-struct vtable. Interfaces
    // always expose their interface struct.
    if !isInterface, vtableCType == nil { return "" }

    let selfType = "UnsafeMutablePointer<\(ctype)>?"
    let handleType = "UnsafeMutablePointer<\(ctype)>"
    let registeredName = "Swift" + cPrefix + record.name
    let quarkName = registeredName + "-swift-instance"

    let vfuncs = renderableVirtualMethods(of: record)
    guard let vtableCType, !vfuncs.isEmpty else {
        return buildMinimalSubclassingCode(baseName: baseName, ctype: ctype, selfType: selfType,
                                           handleType: handleType, getType: getType,
                                           registeredName: registeredName, quarkName: quarkName,
                                           isInterface: isInterface)
    }

    var lines: [String] = []
    lines.append("// MARK: - \(record.name.swift) \(isInterface ? "interface implementation" : "subclassing") support")
    lines.append("")
    lines.append("/// Base class for \(isInterface ? "implementing the `\(record.name.swift)` interface" : "subclassing `\(record.name.swift)`") in Swift.")
    lines.append(implementationAvailability)
    lines.append("open class \(baseName) {")
    lines.append("    /// Pointer to the underlying GObject, usable wherever a `\(ctype)` is expected.")
    lines.append("    public let handle: \(handleType)")
    lines.append("")
    lines.append("    public init() {")
    lines.append("        handle = \(baseName).makeInstance()")
    lines.append("        \(baseName).associate(self, with: handle)")
    lines.append("    }")
    lines.append("")
    lines.append("    deinit {")
    lines.append("        g_object_unref(UnsafeMutableRawPointer(handle))")
    lines.append("    }")

    for vfunc in vfuncs {
        lines.append("")
        lines.append(contentsOf: overridableMethod(vfunc).map { "    " + $0 })
    }

    lines.append("")
    lines.append(contentsOf: registrationMachinery(baseName: baseName, ctype: ctype, selfType: selfType,
                                                   handleType: handleType, getType: getType,
                                                   registeredName: registeredName, quarkName: quarkName,
                                                   isInterface: isInterface, vtableCType: vtableCType,
                                                   vfuncs: vfuncs).map { "    " + $0 })

    for vfunc in vfuncs {
        lines.append("")
        lines.append(contentsOf: thunk(vfunc, baseName: baseName, selfType: selfType).map { "    " + $0 })
    }

    lines.append("}")
    lines.append("")
    return lines.joined(separator: "\n")
}

// MARK: - Virtual method modelling

/// A virtual method reduced to what the emitter needs, with async pairs folded
/// into a single asynchronous entry.
private struct RenderableVFunc {
    var swiftName: String
    /// vtable field names to install (one for a plain method, two for an async pair)
    var installFields: [String]
    var params: [(label: String, type: String)]
    var returnType: String   // "" means Void
    var isAsync: Bool
    var asyncThrows: Bool
    /// vtable field name of the `_async` entry (async only)
    var asyncField: String
    /// vtable field name of the `_finish` entry (async only)
    var finishField: String
    /// C parameter types of the `_async` entry excluding self (async only)
    var asyncCParams: [(name: String, type: String)]
}

private func renderableVirtualMethods(of record: GIR.Record) -> [RenderableVFunc] {
    let all = record.virtualMethods
    let byName = Dictionary(all.map { ($0.name, $0) }) { a, _ in a }
    var consumed = Set<String>()
    var result: [RenderableVFunc] = []

    for method in all {
        if consumed.contains(method.name) { continue }

        if method.name.hasSuffix("_async"),
           method.args.contains(where: { $0.typeRef.type.ctype.contains("GAsyncReadyCallback") }),
           let base = method.name.stringByRemoving(suffix: "_async"),
           let finish = byName[base + "_finish"],
           let async = renderAsyncPair(async: method, finish: finish, base: base) {
            consumed.insert(method.name)
            consumed.insert(base + "_finish")
            result.append(async)
            continue
        }

        if let plain = renderPlain(method) {
            result.append(plain)
        }
    }
    return result
}

private func renderPlain(_ method: GIR.Method) -> RenderableVFunc? {
    if method.throwsError { return nil }
    var params: [(String, String)] = []
    for arg in method.args where !arg.instance {
        guard let type = simpleRenderedType(arg) else { return nil }
        params.append((arg.name.snakeCase2camelCase, type))
    }
    var returnType = ""
    if !method.returns.isVoid {
        if method.returns.isArray || method.returns.knownType is GIR.Callback { return nil }
        guard let r = renderableType(method.returns.typeRef) else { return nil }
        returnType = r
    }
    return RenderableVFunc(swiftName: method.name.snakeCase2camelCase, installFields: [method.name],
                           params: params, returnType: returnType, isAsync: false, asyncThrows: false,
                           asyncField: "", finishField: "", asyncCParams: [])
}

private func renderAsyncPair(async: GIR.Method, finish: GIR.Method, base: String) -> RenderableVFunc? {
    if finish.args.filter({ !$0.instance }).count > 1 { return nil }
    var returnType = ""
    if !finish.returns.isVoid {
        if finish.returns.isArray || finish.returns.knownType is GIR.Callback { return nil }
        guard let r = renderableType(finish.returns.typeRef) else { return nil }
        returnType = r
    }
    // Only pointer-returning or void async methods are folded; the GTask result
    // bridge below handles exactly those.
    let isPointer = returnType.contains("Unsafe") || returnType.contains("OpaquePointer")
    guard finish.returns.isVoid || isPointer else { return nil }

    var params: [(String, String)] = []
    var asyncCParams: [(String, String)] = []
    for arg in async.args where !arg.instance {
        let ctype = arg.typeRef.type.ctype
        if ctype.contains("GAsyncReadyCallback") || ctype == "gpointer" { continue }
        guard arg.direction == .in, !arg.isArray, !arg.varargs else { return nil }
        let type = cOptional(arg.typeRef.fullUnderlyingCName)
        guard !type.isEmpty else { return nil }
        params.append((arg.name.snakeCase2camelCase, type))
        asyncCParams.append((arg.name.snakeCase2camelCase, type))
    }
    return RenderableVFunc(swiftName: base.snakeCase2camelCase, installFields: [async.name, finish.name],
                           params: params, returnType: returnType, isAsync: true,
                           asyncThrows: finish.throwsError, asyncField: async.name,
                           finishField: finish.name, asyncCParams: asyncCParams)
}

// MARK: - Overridable Swift methods

private func overridableMethod(_ vfunc: RenderableVFunc) -> [String] {
    let paramList = vfunc.params.map { "\(escaped($0.label)): \($0.type)" }.joined(separator: ", ")
    let ret = vfunc.returnType.isEmpty ? "" : " -> \(vfunc.returnType)"
    if vfunc.isAsync {
        let effects = vfunc.asyncThrows ? " async throws" : " async"
        return [asyncAvailability,
                "@MainActor open func \(escaped(vfunc.swiftName))(\(paramList))\(effects)\(ret) {",
                "    \(defaultReturnStatement(vfunc.returnType))",
                "}"]
    }
    return ["@MainActor open func \(escaped(vfunc.swiftName))(\(paramList))\(ret) {",
            "    \(defaultReturnStatement(vfunc.returnType))",
            "}"]
}

private func defaultReturnStatement(_ type: String) -> String {
    guard !type.isEmpty else { return "" }
    if type.hasSuffix("!") || type.hasSuffix("?") { return "return nil" }
    switch type {
    case "gboolean", "Bool": return "return 0"
    case "gint", "guint", "gunichar", "gsize", "gssize", "glong", "gulong", "Int", "UInt", "Int32", "UInt32":
        return "return 0"
    case "gfloat", "gdouble", "Double", "Float": return "return 0"
    default: return "fatalError(\"Override this method\")"
    }
}

// MARK: - Registration machinery

private func registrationMachinery(baseName: String, ctype: String, selfType: String, handleType: String,
                                   getType: String, registeredName: String, quarkName: String,
                                   isInterface: Bool, vtableCType: String, vfuncs: [RenderableVFunc]) -> [String] {
    var lines: [String] = []
    lines.append("private final class Box {")
    lines.append("    let instance: \(baseName)")
    lines.append("    init(_ instance: \(baseName)) { self.instance = instance }")
    lines.append("}")
    lines.append("")
    lines.append("private static let quark: GQuark = \"\(quarkName)\".withCString { g_quark_from_string($0) }")
    lines.append("")
    lines.append("private static let gtype: GType = registerType()")
    lines.append("")
    lines.append("private static func registerType() -> GType {")
    lines.append("    var info = GTypeInfo(")
    lines.append("        class_size: guint16(MemoryLayout<GObjectClass>.stride),")
    lines.append("        base_init: nil, base_finalize: nil,")
    if isInterface {
        lines.append("        class_init: { _, _ in }, class_finalize: nil, class_data: nil,")
    } else {
        lines.append("        class_init: classInit, class_finalize: nil, class_data: nil,")
    }
    lines.append("        instance_size: guint16(MemoryLayout<GObject>.stride),")
    lines.append("        n_preallocs: 0, instance_init: { _, _ in }, value_table: nil")
    lines.append("    )")
    let parent = isInterface ? "g_type_from_name(\"GObject\")" : "\(getType)()"
    lines.append("    let type = \"\(registeredName)\".withCString { g_type_register_static(\(parent), $0, &info, GTypeFlags(rawValue: 0)) }")
    if isInterface {
        lines.append("    var ifaceInfo = GInterfaceInfo(interface_init: interfaceInit, interface_finalize: nil, interface_data: nil)")
        lines.append("    g_type_add_interface_static(type, \(getType)(), &ifaceInfo)")
    }
    lines.append("    return type")
    lines.append("}")
    lines.append("")

    if isInterface {
        lines.append("private static let interfaceInit: @convention(c) (gpointer?, gpointer?) -> Void = { ifacePtr, _ in")
        lines.append("    let iface = ifacePtr!.assumingMemoryBound(to: \(vtableCType).self)")
        for vfunc in vfuncs {
            if vfunc.isAsync {
                lines.append("    if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {")
                lines.append("        iface.pointee.\(escaped(vfunc.asyncField)) = \(vfunc.swiftName)AsyncThunk")
                lines.append("        iface.pointee.\(escaped(vfunc.finishField)) = \(vfunc.swiftName)FinishThunk")
                lines.append("    }")
            } else {
                for field in vfunc.installFields {
                    lines.append("    iface.pointee.\(escaped(field)) = unsafeBitCast(\(vfunc.swiftName)Thunk, to: type(of: iface.pointee.\(escaped(field))))")
                }
            }
        }
        lines.append("}")
    } else {
        lines.append("private static let classInit: @convention(c) (gpointer?, gpointer?) -> Void = { classPtr, _ in")
        lines.append("    let klass = classPtr!.assumingMemoryBound(to: \(vtableCType).self)")
        for vfunc in vfuncs {
            if vfunc.isAsync {
                lines.append("    if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {")
                lines.append("        klass.pointee.\(escaped(vfunc.asyncField)) = \(vfunc.swiftName)AsyncThunk")
                lines.append("        klass.pointee.\(escaped(vfunc.finishField)) = \(vfunc.swiftName)FinishThunk")
                lines.append("    }")
            } else {
                for field in vfunc.installFields {
                    lines.append("    klass.pointee.\(escaped(field)) = unsafeBitCast(\(vfunc.swiftName)Thunk, to: type(of: klass.pointee.\(escaped(field))))")
                }
            }
        }
        lines.append("}")
    }
    lines.append("")
    lines.append("private static func makeInstance() -> \(handleType) {")
    lines.append("    return UnsafeMutableRawPointer(g_object_new_with_properties(gtype, 0, nil, nil)!).assumingMemoryBound(to: \(ctype).self)")
    lines.append("}")
    lines.append("")
    lines.append("private static func associate(_ instance: \(baseName), with handle: \(handleType)) {")
    lines.append("    let object = UnsafeMutableRawPointer(handle).assumingMemoryBound(to: GObject.self)")
    lines.append("    g_object_set_qdata_full(object, quark, Unmanaged.passRetained(Box(instance)).toOpaque()) { data in")
    lines.append("        if let data { Unmanaged<Box>.fromOpaque(data).release() }")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append("fileprivate static func instance(from selfPtr: \(selfType)) -> \(baseName) {")
    lines.append("    let object = UnsafeMutableRawPointer(selfPtr!).assumingMemoryBound(to: GObject.self)")
    lines.append("    return Unmanaged<Box>.fromOpaque(g_object_get_qdata(object, quark)!).takeUnretainedValue().instance")
    lines.append("}")
    return lines
}

// MARK: - @convention(c) thunks

private func thunk(_ vfunc: RenderableVFunc, baseName: String, selfType: String) -> [String] {
    if vfunc.isAsync {
        return asyncThunks(vfunc, baseName: baseName, selfType: selfType)
    }
    let cParams = ([("swiftInstancePtr", selfType)] + vfunc.params.map { ($0.label, $0.type) })
    let cParamTypes = cParams.map { $0.1 }.joined(separator: ", ")
    let ret = vfunc.returnType.isEmpty ? "Void" : vfunc.returnType
    let callArgs = vfunc.params.map { "\(escaped($0.label)): \(escaped($0.label))" }.joined(separator: ", ")
    let returnKeyword = vfunc.returnType.isEmpty ? "" : "return "
    var lines: [String] = []
    lines.append("private static let \(vfunc.swiftName)Thunk: @convention(c) (\(cParamTypes)) -> \(ret) = { \(cParams.map { escaped($0.0) }.joined(separator: ", ")) in")
    for param in cParams {
        lines.append("    nonisolated(unsafe) let \(escaped(param.0)) = \(escaped(param.0))")
    }
    lines.append("    \(returnKeyword)MainActor.assumeIsolated { instance(from: swiftInstancePtr).\(escaped(vfunc.swiftName))(\(callArgs)) }")
    lines.append("}")
    return lines
}

private func asyncThunks(_ vfunc: RenderableVFunc, baseName: String, selfType: String) -> [String] {
    let cParams = [("swiftInstancePtr", selfType)] + vfunc.asyncCParams.map { ($0.name, $0.type) }
        + [("cancellable", "UnsafeMutablePointer<GCancellable>?"), ("callback", "GAsyncReadyCallback?"), ("userData", "gpointer?")]
    // Cancellable is already among asyncCParams if the vtable had it; avoid duplicating.
    var seen = Set<String>()
    let dedupedCParams = cParams.filter { seen.insert($0.0).inserted }
    let cParamTypes = dedupedCParams.map { $0.1 }.joined(separator: ", ")
    let callArgs = vfunc.params.map { "\(escaped($0.label)): \(escaped($0.label))" }.joined(separator: ", ")
    let tryKeyword = vfunc.asyncThrows ? "try " : ""

    var lines: [String] = []
    lines.append(asyncAvailability)
    lines.append("private static let \(vfunc.swiftName)AsyncThunk: @convention(c) (\(cParamTypes)) -> Void = { \(dedupedCParams.map { escaped($0.0) }.joined(separator: ", ")) in")
    for param in dedupedCParams {
        lines.append("    nonisolated(unsafe) let \(escaped(param.0)) = \(escaped(param.0))")
    }
    lines.append("    let object = swiftInstancePtr")
    lines.append("    let task = g_task_new(UnsafeMutableRawPointer(object!), cancellable, callback, userData)")
    lines.append("    _Concurrency.Task { @MainActor in")
    if vfunc.asyncThrows {
        lines.append("        do {")
        if vfunc.returnType.isEmpty {
            lines.append("            \(tryKeyword)await instance(from: object).\(escaped(vfunc.swiftName))(\(callArgs))")
            lines.append("            g_task_return_boolean(task, 1)")
        } else {
            lines.append("            let result = \(tryKeyword)await instance(from: object).\(escaped(vfunc.swiftName))(\(callArgs))")
            lines.append("            g_task_return_pointer(task, result.map { UnsafeMutableRawPointer($0) }, nil)")
        }
        lines.append("        } catch {")
        lines.append("            g_task_return_new_error_literal(task, g_quark_from_string(\"swift-subclassing\"), 0, String(describing: error))")
        lines.append("        }")
    } else {
        if vfunc.returnType.isEmpty {
            lines.append("        await instance(from: object).\(escaped(vfunc.swiftName))(\(callArgs))")
            lines.append("        g_task_return_boolean(task, 1)")
        } else {
            lines.append("        let result = await instance(from: object).\(escaped(vfunc.swiftName))(\(callArgs))")
            lines.append("        g_task_return_pointer(task, result.map { UnsafeMutableRawPointer($0) }, nil)")
        }
    }
    lines.append("        g_object_unref(task)")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    let finishRet = vfunc.returnType.isEmpty ? "gboolean" : vfunc.returnType
    lines.append(asyncAvailability)
    lines.append("private static let \(vfunc.swiftName)FinishThunk: @convention(c) (\(selfType), UnsafeMutablePointer<GAsyncResult>?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> \(finishRet) = { _, result, error in")
    let taskCast = "UnsafeMutableRawPointer(result).map { $0.assumingMemoryBound(to: GTask.self) }"
    if vfunc.returnType.isEmpty {
        lines.append("    return g_task_propagate_boolean(\(taskCast), error)")
    } else {
        lines.append("    return \(taskCast).flatMap { g_task_propagate_pointer($0, error) }?.assumingMemoryBound(to: \(elementType(of: vfunc.returnType)).self)")
    }
    lines.append("}")
    return lines
}

/// Converts an implicitly-unwrapped optional C type to a regular optional,
/// which is valid in every position (nested generics, function types).
private func cOptional(_ type: String) -> String {
    return type.replacingOccurrences(of: "!", with: "?")
}

private func escaped(_ name: String) -> String {
    swiftKeywords.contains(name) ? "`\(name)`" : name
}

/// Returns the rendered Swift-C type for an argument if it is simple enough to
/// forward through a thunk, or nil if the vfunc using it should be skipped.
/// Function-pointer, array, varargs, out/inout and multi-level pointer
/// arguments are considered too exotic and cause the whole vfunc to be omitted.
private func simpleRenderedType(_ arg: GIR.Argument) -> String? {
    guard !arg.isArray, !arg.varargs else { return nil }
    let ctype = arg.typeRef.type.ctype
    if ctype.contains("Callback") || ctype.contains("Func") { return nil }
    if arg.knownType is GIR.Callback { return nil }
    if arg.typeRef.constPointers.count > 1 { return nil }
    guard let type = renderableType(arg.typeRef) else { return nil }
    // out/inout parameters are passed as a single pointer; require the rendered
    // type to be a pointer so the thunk's ABI matches the vtable field.
    if arg.direction != .in && !type.contains("Pointer") { return nil }
    return type
}

/// Renders a type reference to its Swift-C form, or nil when the shape is one
/// the thunks cannot reliably match against the imported vtable field.
private func renderableType(_ ref: TypeReference) -> String? {
    let type = cOptional(ref.fullUnderlyingCName)
    if type.isEmpty { return nil }
    for token in ["(", "->", "gpointer", "GError", "Callback", "Func", "@escaping", "UnsafeMutablePointer<Unsafe", "UnsafeMutablePointer<Const"] {
        if type.contains(token) { return nil }
    }
    return type
}

/// Extracts the pointee element type from a pointer type like
/// `UnsafeMutablePointer<GListModel>!` -> `GListModel`.
private func elementType(of pointerType: String) -> String {
    guard let open = pointerType.firstIndex(of: "<"), let close = pointerType.lastIndex(of: ">") else {
        return "GObject"
    }
    return String(pointerType[pointerType.index(after: open)..<close])
}

// MARK: - Minimal support (no renderable vfuncs)

private func buildMinimalSubclassingCode(baseName: String, ctype: String, selfType: String, handleType: String,
                                         getType: String, registeredName: String, quarkName: String,
                                         isInterface: Bool) -> String {
    // A type with no overridable vtable entries can still be subclassed to add
    // Swift state; emit just the registration and instance association.
    var lines: [String] = []
    lines.append("// MARK: - \(baseName) (no overridable virtual methods)")
    lines.append(implementationAvailability)
    lines.append("open class \(baseName) {")
    lines.append("    public let handle: \(handleType)")
    lines.append("    public init() {")
    lines.append("        handle = \(baseName).makeInstance()")
    lines.append("        \(baseName).associate(self, with: handle)")
    lines.append("    }")
    lines.append("    deinit { g_object_unref(UnsafeMutableRawPointer(handle)) }")
    lines.append("")
    lines.append("    private final class Box { let instance: \(baseName); init(_ i: \(baseName)) { instance = i } }")
    lines.append("    private static let quark: GQuark = \"\(quarkName)\".withCString { g_quark_from_string($0) }")
    lines.append("    private static let gtype: GType = {")
    lines.append("        var info = GTypeInfo(class_size: guint16(MemoryLayout<GObjectClass>.stride), base_init: nil, base_finalize: nil, class_init: { _, _ in }, class_finalize: nil, class_data: nil, instance_size: guint16(MemoryLayout<GObject>.stride), n_preallocs: 0, instance_init: { _, _ in }, value_table: nil)")
    let parent = isInterface ? "g_type_from_name(\"GObject\")" : "\(getType)()"
    if isInterface {
        lines.append("        let type = \"\(registeredName)\".withCString { g_type_register_static(\(parent), $0, &info, GTypeFlags(rawValue: 0)) }")
        lines.append("        var ifaceInfo = GInterfaceInfo(interface_init: { _, _ in }, interface_finalize: nil, interface_data: nil)")
        lines.append("        g_type_add_interface_static(type, \(getType)(), &ifaceInfo)")
        lines.append("        return type")
    } else {
        lines.append("        return \"\(registeredName)\".withCString { g_type_register_static(\(parent), $0, &info, GTypeFlags(rawValue: 0)) }")
    }
    lines.append("    }()")
    lines.append("    private static func makeInstance() -> \(handleType) { UnsafeMutableRawPointer(g_object_new_with_properties(gtype, 0, nil, nil)!).assumingMemoryBound(to: \(ctype).self) }")
    lines.append("    private static func associate(_ instance: \(baseName), with handle: \(handleType)) {")
    lines.append("        let object = UnsafeMutableRawPointer(handle).assumingMemoryBound(to: GObject.self)")
    lines.append("        g_object_set_qdata_full(object, quark, Unmanaged.passRetained(Box(instance)).toOpaque()) { data in if let data { Unmanaged<Box>.fromOpaque(data).release() } }")
    lines.append("    }")
    lines.append("}")
    lines.append("")
    return lines.joined(separator: "\n")
}
