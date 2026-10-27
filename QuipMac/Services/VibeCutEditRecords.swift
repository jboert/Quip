// VibeCutEditRecords.swift
// QuipMac — Q-77: lets the VibeCut sync use the text a user saved in VibeCut's
// prompt editor instead of the catalog body.
//
// The editor writes `<id>.scpt` (compiled) plus `<id>.edit.json` (an `EditRecord`)
// under `~/Library/Application Support/VibeCut/actions/`. This file mirrors the
// trust rule VibeCut itself applies when it reads a record back
// (`UserPromptOverlayStorage.OverlayStorage.read`): safe id, record.id == id,
// type in {text, screenshot}, mode in {paste, send}, and the record's SHA-256
// matches the `.scpt` bytes. Anything missing or failing a check leaves the
// catalog prompt untouched.
//
// Prompt Lab versions are deliberately NOT read: they are experiments, not what
// the user saved as their live button text.

import Foundation
import CryptoKit

enum VibeCutEditRecords {
    /// VibeCut's saved-action directory (`~/Library/Application Support/VibeCut/actions`).
    static func defaultActionsDirectory() -> URL {
        URL(fileURLWithPath:
            ("~/Library/Application Support/VibeCut/actions" as NSString).expandingTildeInPath)
    }

    /// Mirror of `PromptActionResolution.isSafeID` in VibeCut. No slashes, no
    /// leading dot, so an id can never escape the actions directory.
    static func isSafeID(_ id: String) -> Bool {
        id.range(of: "\\A[A-Za-z0-9_-][A-Za-z0-9._-]*\\z", options: .regularExpression) != nil
    }

    /// Default Swift Codable keys, as VibeCut writes them. Only the fields we
    /// apply or validate are declared; the rest are ignored on decode.
    private struct EditRecord: Decodable {
        let id: String
        let prompt: String
        let mode: String
        let type: String
        let scriptSHA256: String
    }

    /// Returns `catalog` with `prompt`/`mode`/`type` replaced for every prompt
    /// whose saved edit record validates. Never throws; failures keep the catalog value.
    static func apply(to catalog: VibeCutCatalog, actionsDirectory: URL) -> VibeCutCatalog {
        var out = catalog
        for i in out.prompts.indices {
            guard let id = out.prompts[i].id, let record = validRecord(id: id, in: actionsDirectory)
            else { continue }
            out.prompts[i].prompt = record.prompt
            out.prompts[i].mode = record.mode
            out.prompts[i].type = record.type
        }
        return out
    }

    private static func validRecord(id: String, in dir: URL) -> EditRecord? {
        guard isSafeID(id),
              let json = try? Data(contentsOf: dir.appendingPathComponent(id + ".edit.json")),
              let record = try? JSONDecoder().decode(EditRecord.self, from: json),
              record.id == id,
              ["text", "screenshot"].contains(record.type),
              ["paste", "send"].contains(record.mode),
              let script = try? Data(contentsOf: dir.appendingPathComponent(id + ".scpt")),
              record.scriptSHA256 == fingerprint(script)
        else { return nil }
        return record
    }

    private static func fingerprint(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
