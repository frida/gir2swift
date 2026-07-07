//
//  File.swift
//  
//
//  Created by Mikoláš Stuchlík on 17.11.2020.
//
import SwiftLibXML

extension GIR {

    /// an enumeration entry
    public class Enumeration: Datatype {
        /// String representation of `Enumeration`s
        public override var kind: String { return "Enumeration" }
        /// an enumeration value in C is a constant
        public typealias Member = Constant

        /// enumeration values
        public let members: [Member]

        /// Designated initialiser
        /// - Parameters:
        ///   - name: The name of the `Enumeration` to initialise
        ///   - type: C typedef name of the enum
        ///   - members: the cases for this enum
        ///   - comment: Documentation text for the enum
        ///   - introspectable: Set to `true` if introspectable
        ///   - deprecated: Documentation on deprecation status if non-`nil`
        public init(name: String, type: TypeReference, members: [Member], comment: String, introspectable: Bool = false, deprecated: String? = nil) {
            self.members = members
            super.init(name: name, type: type, comment: comment, introspectable: introspectable, deprecated: deprecated)
        }

        /// Initialiser to construct an enumeration from XML
        /// - Parameters:
        ///   - node: `XMLElement` to construct this enum from
        ///   - index: Index within the siblings of the `node`
        public init(node: XMLElement, at index: Int) {
            let mem = node.children.lazy.filter { $0.name == "member" }
            members = mem.enumerated().map { Member(node: $0.1, at: $0.0) }
            super.init(node: node, at: index)
        }

        /// Register this type as an enumeration type.
        ///
        /// Enumerations are wrapped in a native `RawRepresentable` struct
        /// (distinct from the imported C enum), so a conversion between the
        /// C type and the wrapper is registered — mirroring `Bitfield` — to
        /// bridge at the C boundary via `init(_ enumValue:)` / `value`.
        @inlinable
        override public func registerKnownType() {
            let type = typeRef.type
            let ctype = GIRType(name: type.typeName, typeName: type.typeName, ctype: type.ctype)

            if !GIR.enums.contains(ctype) {
                let c = BitfieldTypeConversion(source: ctype, target: type)
                type.conversions[ctype] = [c, c]
                GIR.enums.insert(ctype)
            }

            if !GIR.enums.contains(type) {
                let c = BitfieldTypeConversion(source: type, target: ctype)
                type.conversions[ctype] = [c, c]
                GIR.enums.insert(type)
            }
        }
    }
    
}

