// Fastfile.swift
// Copyright (c) 2021 Tim Oliver
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

class Fastfile: LaneFile {
    /// The path to the changelog file
    var changelogPath: String { return "CHANGELOG.md" }

    /// The name of the temporary keychain where all of the
    /// signing credentials are stored
    var keychainName: String { return "GitHubActions" }

    /// Runs a lane that goes takes a provided version number,
    /// updates the project files with that version number, and then
    /// builds, signs and releases a new copy of the app under that version
	func releaseLane() {
        desc("Build, sign, notarize and release a new version of YouTube Music")

        // Get the info we need from the environment
        let newVersion = getNewVersion(from: environmentVariable(get: "YTM_VERSION"))

        // Load the changelog text
        let changelogURL = URL(fileURLWithPath: changelogPath)
        guard var changelog = try? String(contentsOf: changelogURL) else {
            fatalError("Was unable to locate \(changelogPath)")
        }

        // From the changelog, get the latest changes, and the previous version
        guard let changelogChanges = parseChangelog(changelog) else {
            fatalError("Was unable to properly read CHANGELOG.md")
        }

        // Before we proceed, verify the new version provided is valid
        verifyNewVersion(newVersion, oldVersion: changelogChanges.previousVersion)

        // Install any needed CocoaPods dependencies
        cocoapods(cleanInstall: true, useBundleExec: true)

        // Make a temporary keychain to store our signing credentials
        setUpKeychain()

        // Install the Apple signing identity from GitHub secrets
        installSigningIdentity()

        // Install Sparkle private key from GitHub secrets
        installSparklePrivateKey()

        // Download and build Markdown to HTML utility
        prepareInkUtility()

        // Bump the version in the Info.plist
        setInfoPlistValue(key: "CFBundleShortVersionString",
                          value: newVersion,
                          path: "YT Music/Supporting/Info.plist")

        // Build the app (All of the build settings are in the project)
        buildMacApp(codesigningIdentity: environmentVariable(get: "CODESIGN_IDENTITY"),
                    exportMethod: "developer-id")

        // Notarize and staple the app
        notarize(package: "YT Music.app",
                 username: environmentVariable(get: "AC_NOTARIZE_EMAIL"),
                 ascProvider: environmentVariable(get: "AC_NOTARIZE_TEAM"),
                 verbose: true)

        // Generate the final ZIP for the build
        let archiveName = "YT-Music-\(newVersion).zip"
        sh(command: "ditto -c -k --sequesterRsrc --keepParent YT\\ Music.app \(archiveName)",
           log: false)

        // Generate the Sparkle app cast for this new version
        do {
            try updateAppCast(fileName: archiveName,
                               newVersion: newVersion,
                               changes: changelogChanges.changes)
        } catch { fatalError("Unable to update Appcast.xml") }

        // Update the CHANGELOG
        do { try updateChanglog(&changelog, newVersion: newVersion) }
        catch { fatalError("Unable to update Changelog \(error)") }

        // Commit all of the files we changed
        gitCommit(path: ["YT Music/Supporting/Info.plist", "CHANGELOG.md"],
                  message: "Release version \(newVersion)! 🎉")

        // Make a tag for this release
        addGitTag(tag: newVersion)

        // Push to remote
        pushToGitRemote()

        // Push GitHub Release
        setGithubRelease(repositoryName: "TimOliver/YouTube-Music",
                         apiBearer: environmentVariable(get: "GITHUB_TOKEN"),
                         tagName: newVersion,
                         name: newVersion,
                         description: changelogChanges.changes,
                         uploadAssets: [archiveName])
	}
}

extension Fastfile {

    /// Parse the new version out of the environment variable
    func getNewVersion(from string: String)-> String {
        // Run a regex to extract just the version number (In case they prefixed v at the front)
        guard let range = string.ranges(for: "([0-9]+\\.[0-9]+\\.[0-9]+)")?.first else {
            fatalError("A valid version number wasn't provided (eg '1.0.0')")
        }

        return String(string[Range(range, in: string)!])
    }

    /// Verify the version provided is in a valid format
    func verifyNewVersion(_ newVersion: String, oldVersion: String) {
        // Check a tag doesn't already exist
        if gitTagExists(tag: newVersion) {
            fatalError("Tag for version \(newVersion) already exists")
        }

        // Check this version is actually higher than the older version
        if newVersion.compare(oldVersion, options: .numeric) != .orderedDescending {
            fatalError("New version \(newVersion) was not higher than older version \(oldVersion)")
        }
    }

    /// Create a temporary keychain to store the signing credentials
    func setUpKeychain() {

        // Delete the keychain if it already exists
        deleteKeychain(name: keychainName)

        // Create the new keychain
        createKeychain(name: keychainName,
                       password: environmentVariable(get: "MATCH_KEYCHAIN_PASSWORD"),
                       defaultKeychain: true,
                       unlock: true,
                       timeout: 600, // 10 minutes
                       lockAfterTimeout: false,
                       requireCreate: true)
    }

    /// Extract the signing identity from GitHub secrets and install it in our keychain
    func installSigningIdentity() {
        // Decode the signing cert and save to disk
        let certificateString = environmentVariable(get: "SIGNING_CERT")
        let data = Data(base64Encoded: certificateString, options: .ignoreUnknownCharacters)
        let certificateURL = URL(fileURLWithPath: "Certificate.p12")
        do { try data?.write(to: certificateURL) }
        catch { fatalError("Unable to save signing identity to disk") }

        // Import into the keychain
        importCertificate(certificatePath: "Certificate.p12",
                          certificatePassword: environmentVariable(get: "SIGNING_CERT_PASSWORD"),
                          keychainName: "\(keychainName)-db",
                          keychainPassword: environmentVariable(get: "MATCH_KEYCHAIN_PASSWORD"))
    }

    func installSparklePrivateKey() {
        // Export the key from Secrets to disk
        let sparklePrivateKey = environmentVariable(get: "SPARKLE_PRIVATE_KEY")
        let path = "key.pem"
        do { try sparklePrivateKey.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { fatalError("Could not save Sparkle private key") }

        // Import into the keychain
        sh(command: "./Pods/Sparkle/bin/generate_keys -f \(path)", log: false)
    }

    /// In order to convert Markdown to HTML, download and build a copy
    /// of John Sundell's Ink library, and build a copy.
    func prepareInkUtility() {
        // Clone the repo, and build it
        sh(command: "git clone https://github.com/johnsundell/Ink.git;cd Ink; make; cd ..",
           log: false)
    }

    /// Take the changelog and extract the information we need to push
    /// a new release (mainly the unreleased changes, and the last released version)
    /// - Parameter changelog: The complete changelog loaded from disk
    /// - Returns: A tuple containing the unreleased text as markdown, and the previous version
    func parseChangelog(_ changelog: String) -> (changes: String, previousVersion: String)? {
        // Create a regular expression that extracts everything between the
        // '[Unreleased]' and the previous version, as well as the previous version
        guard let ranges = changelog.ranges(for: "## \\[Unreleased\\](.*?)## \\[([0-9]+\\.[0-9]+\\.[0-9]+)\\]"),
              ranges.count > 1 else {  return nil }

        // Extract the changes, and trim outer white space
        let changes = String(changelog[Range(ranges[0], in: changelog)!])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract the previous version number
        let previousVersion = String(changelog[Range(ranges[1], in: changelog)!])

        // Return the two as a tuple
        return (changes: changes, previousVersion: previousVersion)
    }

    /// Update the Sparkle app cast file with a new entry for this version
    /// - Parameters:
    ///   - fileName: The name of the zip file on disk that will be distributed
    ///   - newVersion: The new version of the app
    ///   - changes: The changes in markdown as extracted from the changelog
    /// - Throws: Throws an error if any step of the process fails
    func updateAppCast(fileName: String,
                       newVersion: String,
                       changes: String?) throws {
        // Load the appcast file and insert the string
        let appcastURL = URL(fileURLWithPath: "Appcast.xml")
        guard var appcast = try? String(contentsOf: appcastURL) else {
            throw "Unable to locate Appcast.xml"
        }

        // Work out where we need to inject this code before proceeding
        guard let range = appcast.ranges(for: "(.*?\\n)[ ]+<item>")?.first else {
            throw "Unable to parse Appcast.xml"
        }

        // Fetch the minimum supported version of macOS in this build
        let minimumSystemVersion = getInfoPlistValue(key: "LSMinimumSystemVersion",
                                                     path: "YT Music.app/Contents/Info.plist")


        // Sign the ZIP file with Sparkle's private key
        unlockKeychain(path: keychainName,
                       password: environmentVariable(get: "MATCH_KEYCHAIN_PASSWORD"),
                       setDefault: true)
        let signature = sh(command: "./Pods/Sparkle/bin/sign_update \(fileName)",
                           log: false).trimmingCharacters(in: .whitespacesAndNewlines)

        // Convert the changes from markdown to HTML using Ink
        var sanitizedChanges = changes ?? "No changes listed for this version."
        sanitizedChanges = sanitizedChanges.replacingOccurrences(of: "\"", with: "\\\"")
        let htmlChanges = sh(command: "./Ink/.build/release/ink-cli -m \"\(sanitizedChanges)\"",
                             log: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Generate today's date in the appropriate format
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        let dateString = dateFormatter.string(from: Date())

        // Generate the item block for this app cast with all of our generated data
        let appcastItem = """
                <item>
                    <title>Version \(newVersion)</title>
                    <description>
                        <![CDATA[
                        \(htmlChanges)
                        ]]>
                    </description>
                    <pubDate>\(dateString)</pubDate>
                    <sparkle:minimumSystemVersion>\(minimumSystemVersion)</sparkle:minimumSystemVersion>
                    <enclosure url="https://github.com/TimOliver/YouTube-Music/releases/download/\(newVersion)/\(fileName)"
                    sparkle:version="8" sparkle:shortVersionString="\(newVersion)"
                    \(signature)
                    type="application/octet-stream"/>
                </item>\n
        """

        appcast.insert(contentsOf: appcastItem, at: appcast.index(appcast.startIndex, offsetBy: range.length))
        try appcast.write(to: appcastURL, atomically: true, encoding: .utf8)
    }

    func updateChanglog(_ changelog: inout String, newVersion: String) throws {
        //  Find the range of the unreleased block
        guard let unreleasedBlock = changelog.ranges(for: "(##\\s\\[Unreleased\\]\\n)")?.first else {
            throw "Could not find '## [Unreleased]' in Changelog"
        }

        // Insert the new release number under it
        // e.g
        // ## [Unreleased]
        //
        // ## [1.0.0]
        changelog.insert(contentsOf: "\n## [\(newVersion)]\n",
                         at: changelog.index(changelog.startIndex, offsetBy: NSMaxRange(unreleasedBlock)))

        // Update the links at the bottom of the changelog with the new version
        guard let linkRanges = changelog.ranges(for: "(\\[Unreleased\\]:\\s(.*\\/)([0-9]+\\.[0-9]+\\.[0-9]+)\\.\\.\\.HEAD)"),
              linkRanges.count == 3 else {
            fatalError("Unable to find footer links in Changelog")
        }
        // Get the previous version from the links (eg 1.0.6)
        let previousVersion = changelog[Range(linkRanges[2], in: changelog)!]

        // Get the base URL
        let baseURL = changelog[Range(linkRanges[1], in: changelog)!]

        // Insert a new entry below the unreleased block for the previous version
        changelog.insert(contentsOf: "[\(newVersion)]: \(baseURL)\(previousVersion)...\(newVersion)\n",
                         at: changelog.index(changelog.startIndex, offsetBy: NSMaxRange(linkRanges[0])))

        // Update the unreleased block with the new version
        // eg [Unreleased]: https://github.com/steve228uk/YouTube-Music/compare/1.0.6...HEAD
        // to
        // [Unreleased]: https://github.com/steve228uk/YouTube-Music/compare/1.1.0...HEAD
        changelog.replaceSubrange(Range(linkRanges[2], in: changelog)!, with: newVersion)

        // Write this new changelog back to disk
        try changelog.write(toFile: changelogPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Regular Expression Extension -
extension String {
    /// Given a regular expression pattern, return an array
    /// of all of the ranges of the matching groups found
    /// - Parameter pattern: The regular expression to use
    /// - Returns: An array of ranges, or nil if none were found
    public func ranges(for pattern: String) -> [NSRange]? {
        // Cover the entire string when searching
        let stringRange = NSRange(location: 0, length: self.count)

        // Define the regular expression, explicitly including new line characters
        let regex = try! NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        // Run the query, and verify at least one group was found
        guard let matches = regex.firstMatch(in: self, options: [], range: stringRange),
              matches.numberOfRanges > 1 else { return nil }

        // Convert the results to an array of ranges
        // (Skip the first as that is the matching block, and not a group)
        return (1..<matches.numberOfRanges).map { matches.range(at: $0) }
    }
}

// Enable throwing string errors
extension String: Error {}