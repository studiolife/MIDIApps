/*
 Copyright (c) 2021, Kurt Revis.  All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 * Neither the name of Kurt Revis, nor Snoize, nor the names of other contributors may be used to endorse or promote products derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import CoreMIDI

protocol CoreMIDIObjectListable: CoreMIDIObjectWrapper {

    static var midiObjectType: MIDIObjectType { get }
    static func midiObjectCount(_ context: CoreMIDIContext) -> Int
    static func midiObjectSubscript(_ context: CoreMIDIContext, _ index: Int) -> MIDIObjectRef

    init(context: CoreMIDIContext, objectRef: MIDIObjectRef)

    var uniqueID: MIDIUniqueID { get } // So list can look up object by uniqueID

}

extension CoreMIDIObjectListable {

    static func fetchMIDIObjectRefs(_ context: CoreMIDIContext) -> [MIDIObjectRef] {
        var objectRefs: [MIDIObjectRef] = []

        let count = midiObjectCount(context)
        for index in 0 ..< count {
            let objectRef = midiObjectSubscript(context, index)
            if objectRef != 0 {
                objectRefs.append(objectRef)
            }
        }

        return objectRefs
    }

}

protocol CoreMIDIObjectList {

    var midiObjectType: MIDIObjectType { get }

    func objectPropertyChanged(midiObjectRef: MIDIObjectRef, property: CFString)

    func objectWasAdded(midiObjectRef: MIDIObjectRef, parentObjectRef: MIDIObjectRef, parentType: MIDIObjectType, preNotificationClosure: (() -> Void)?)
    func objectWasRemoved(midiObjectRef: MIDIObjectRef, parentObjectRef: MIDIObjectRef, parentType: MIDIObjectType)

    func updateList()

}
