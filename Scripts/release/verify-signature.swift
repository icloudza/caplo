// 用 EdDSA 公钥核对 Sparkle 签名：swift verify-signature.swift <公钥 base64> <签名 base64> <文件>
// 与应用内 Sparkle 的校验一致（Ed25519，对整个文件签名），通过返回 0。
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
else {
    FileHandle.standardError.write(Data("参数无效：需要公钥、签名（base64）与文件路径\n".utf8))
    exit(2)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
