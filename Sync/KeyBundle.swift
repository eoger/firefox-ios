/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import FxA
import Account
import SwiftyJSON

private let KeyLength = 32

open class KeyBundle: Hashable {
    let encKey: Data
    let hmacKey: Data

    open class func fromKSync(_ kSync: Data) -> KeyBundle {
        return KeyBundle(encKey: kSync.subdata(in: 0..<KeyLength),
                         hmacKey: kSync.subdata(in: KeyLength..<(2 * KeyLength)))
    }

    open class func random() -> KeyBundle {
        // Bytes.generateRandomBytes uses SecRandomCopyBytes, which hits /dev/random, which
        // on iOS is populated by the OS from kernel-level sources of entropy.
        // That should mean that we don't need to seed or initialize anything before calling
        // this. That is probably not true on (some versions of) OS X.
        return KeyBundle(encKey: Bytes.generateRandomBytes(32), hmacKey: Bytes.generateRandomBytes(32))
    }

    open class var invalid: KeyBundle {
        return KeyBundle(encKeyB64: "deadbeef", hmacKeyB64: "deadbeef")!
    }

    public init?(encKeyB64: String, hmacKeyB64: String) {
        guard let e = Bytes.decodeBase64(encKeyB64),
              let h = Bytes.decodeBase64(hmacKeyB64) else {
            return nil
        }
        self.encKey = e
        self.hmacKey = h
    }

    public init(encKey: Data, hmacKey: Data) {
        self.encKey = encKey
        self.hmacKey = hmacKey
    }

    fileprivate func _hmac(_ ciphertext: Data) -> (data: UnsafeMutablePointer<CUnsignedChar>, len: Int) {
        let hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        let digestLen: Int = Int(CC_SHA256_DIGEST_LENGTH)
        let result = UnsafeMutablePointer<CUnsignedChar>.allocate(capacity: digestLen)
        CCHmac(hmacAlgorithm, hmacKey.getBytes(), hmacKey.count, ciphertext.getBytes(), ciphertext.count, result)
        return (result, digestLen)
    }

    open func hmac(_ ciphertext: Data) -> Data {
        let (result, digestLen) = _hmac(ciphertext)
        let data = NSMutableData(bytes: result, length: digestLen)

        result.deinitialize(count: digestLen)
        result.deallocate()
        return data as Data
    }

    /**
     * Returns a hex string for the HMAC.
     */
    open func hmacString(_ ciphertext: Data) -> String {
        let (result, digestLen) = _hmac(ciphertext)
        let hash = NSMutableString()
        for i in 0..<digestLen {
            hash.appendFormat("%02x", result[i])
        }

        result.deinitialize(count: digestLen)
        result.deallocate()
        return String(hash)
    }

    open func encrypt(_ cleartext: Data, iv: Data?=nil) -> (ciphertext: Data, iv: Data)? {
        let iv = iv ?? Bytes.generateRandomBytes(16)

        let (success, b, copied) = self.crypt(cleartext, iv: iv, op: CCOperation(kCCEncrypt))
        if success == CCCryptorStatus(kCCSuccess) {
            // Hooray!
            let d = Data(bytes: b, count: Int(copied))
            b.deallocate()
            return (d, iv)
        }

        b.deallocate()
        return nil
    }

    // You *must* verify HMAC before calling this.
    open func decrypt(_ ciphertext: Data, iv: Data) -> String? {
        let (success, b, copied) = self.crypt(ciphertext, iv: iv, op: CCOperation(kCCDecrypt))
        if success == CCCryptorStatus(kCCSuccess) {
            // Hooray!
            let d = Data(bytes: b, count: Int(copied))
            let s = String(data: d, encoding: .utf8)
            b.deallocate()
            return s
        }

        b.deallocate()
        return nil
    }

    fileprivate func crypt(_ input: Data, iv: Data, op: CCOperation) -> (status: CCCryptorStatus, buffer: UnsafeMutableRawPointer, count: Int) {
        let resultSize = input.count + kCCBlockSizeAES128
        var copied: Int = 0
        let result = UnsafeMutableRawPointer.allocate(byteCount: resultSize, alignment: MemoryLayout<Void>.size)

        let success: CCCryptorStatus =
        CCCrypt(op,
                CCHmacAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                encKey.getBytes(),
                kCCKeySizeAES256,
                iv.getBytes(),
                input.getBytes(),
                input.count,
                result,
                resultSize,
                &copied
        )

        return (success, result, copied)
    }

    open func verify(hmac: Data, ciphertextB64: Data) -> Bool {
        let expectedHMAC = hmac
        let computedHMAC = self.hmac(ciphertextB64)
        return (expectedHMAC == computedHMAC)
    }

    /**
     * Swift can't do functional factories. I would like to have one of the following
     * approaches be viable:
     *
     * 1. Derive the constructor from the consumer of the factory.
     * 2. Accept a type as input.
     *
     * Neither of these are viable, so we instead pass an explicit constructor closure.
     *
     * Most of these approaches produce either odd compiler errors, or -- worse --
     * compile and then yield runtime EXC_BAD_ACCESS (see Radar 20230159).
     *
     * For this reason, be careful trying to simplify or improve this code.
     */
    open func factory<T: CleartextPayloadJSON>(_ f: @escaping (JSON) -> T) -> (String) -> T? {
        return { (payload: String) -> T? in
            let potential = EncryptedJSON(json: payload, keyBundle: self)
            if !potential.isValid() {
                return nil
            }

            let cleartext = potential.cleartext
            if cleartext == nil {
                return nil
            }
            return f(cleartext!)
        }
    }

    // TODO: how much do we want to move this into EncryptedJSON?
    open func serializer<T: CleartextPayloadJSON>(_ f: @escaping (T) -> JSON) -> (Record<T>) -> JSON? {
        return { (record: Record<T>) -> JSON? in
            let json = f(record.payload)
            if json.isNull() {
                // This should never happen, but if it does, we don't want to leak this
                // record to the server!
                return nil
            }
            // Get the most basic kind of encoding: no pretty printing.
            // This can throw; if so, we return nil.
            // `rawData` simply calls JSONSerialization.dataWithJSONObject:options:error, which
            // guarantees UTF-8 encoded output.

            guard let bytes: Data = try? json.rawData(options: []) else { return nil }

            // Given a valid non-null JSON object, we don't ever expect a round-trip to fail.
            assert(!JSON(bytes).isNull())

            // We pass a null IV, which means "generate me a new one".
            // We then include the generated IV in the resulting record.
            if let (ciphertext, iv) = self.encrypt(bytes, iv: nil) {
                // So we have the encrypted payload. Now let's build the envelope around it.
                let ciphertext = ciphertext.base64EncodedString

                // The HMAC is computed over the base64 string. As bytes. Yes, I know.
                if let encodedCiphertextBytes = ciphertext.data(using: .ascii, allowLossyConversion: false) {
                    let hmac = self.hmacString(encodedCiphertextBytes)
                    let iv = iv.base64EncodedString

                    // The payload is stringified JSON. Yes, I know.
                    let payload: Any = JSON(["ciphertext": ciphertext, "IV": iv, "hmac": hmac]).stringValue()! as Any
                    let obj = ["id": record.id,
                               "sortindex": record.sortindex,
                               // This is how SwiftyJSON wants us to express a null that we want to
                               // serialize. Yes, this is gross.
                               "ttl": record.ttl ?? NSNull(),
                               "payload": payload]
                    return JSON(obj)
                }
            }
            return nil
        }
    }

    open func asPair() -> [String] {
        return [self.encKey.base64EncodedString, self.hmacKey.base64EncodedString]
    }

    open var hashValue: Int {
        return "\(self.encKey.base64EncodedString) \(self.hmacKey.base64EncodedString)".hashValue
    }

    public static func ==(lhs: KeyBundle, rhs: KeyBundle) -> Bool {
        return lhs.encKey == rhs.encKey && lhs.hmacKey == rhs.hmacKey
    }
}

open class Keys: Equatable {
    let valid: Bool
    let defaultBundle: KeyBundle
    var collectionKeys: [String: KeyBundle] = [String: KeyBundle]()

    public init(defaultBundle: KeyBundle) {
        self.defaultBundle = defaultBundle
        self.valid = true
    }

    public init(payload: KeysPayload?) {
        if let payload = payload, payload.isValid(),
            let keys = payload.defaultKeys {
            self.defaultBundle = keys
            self.collectionKeys = payload.collectionKeys
            self.valid = true
            return
        }
        self.defaultBundle = KeyBundle.invalid
        self.valid = false
    }

    public convenience init(downloaded: EnvelopeJSON, master: KeyBundle) {
        let f: (JSON) -> KeysPayload = { KeysPayload($0) }
        let keysRecord = Record<KeysPayload>.fromEnvelope(downloaded, payloadFactory: master.factory(f))
        self.init(payload: keysRecord?.payload)
    }

    open class func random() -> Keys {
        return Keys(defaultBundle: KeyBundle.random())
    }

    open func forCollection(_ collection: String) -> KeyBundle {
        if let bundle = collectionKeys[collection] {
            return bundle
        }
        return defaultBundle
    }

    open func encrypter<T>(_ collection: String, encoder: RecordEncoder<T>) -> RecordEncrypter<T> {
        return RecordEncrypter(bundle: forCollection(collection), encoder: encoder)
    }

    open func asPayload() -> KeysPayload {
        let json: JSON = JSON([
            "id": "keys",
            "collection": "crypto",
            "default": self.defaultBundle.asPair(),
            "collections": mapValues(self.collectionKeys, f: { $0.asPair() })
        ])
        return KeysPayload(json)
    }

    public static func ==(lhs: Keys, rhs: Keys) -> Bool {
        return lhs.valid == rhs.valid &&
            lhs.defaultBundle == rhs.defaultBundle &&
            lhs.collectionKeys == rhs.collectionKeys
    }
}

/**
 * Yup, these are basically typed tuples.
 */
public struct RecordEncoder<T: CleartextPayloadJSON> {
    let decode: (JSON) -> T
    let encode: (T) -> JSON
}

public struct RecordEncrypter<T: CleartextPayloadJSON> {
    let serializer: (Record<T>) -> JSON?
    let factory: (String) -> T?

    init(bundle: KeyBundle, encoder: RecordEncoder<T>) {
        self.serializer = bundle.serializer(encoder.encode)
        self.factory = bundle.factory(encoder.decode)
    }

    init(serializer: @escaping (Record<T>) -> JSON?, factory: @escaping (String) -> T?) {
        self.serializer = serializer
        self.factory = factory
    }
}

