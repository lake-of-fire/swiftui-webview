// From: https://github.com/brave/brave-ios/blob/77626701b8829d3696e057ccb3c39f7bd268eaec/Sources/Shared/Extensions/URLExtensions.swift#L220
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

extension URL {
    public func normalizedHost(stripWWWSubdomainOnly: Bool = false) -> String? {
      // Use components.host instead of self.host since the former correctly preserves
      // brackets for IPv6 hosts, whereas the latter strips them.
      guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false), var host = components.host, host != "" else {
        return nil
      }

      let textToReplace = stripWWWSubdomainOnly ? "^(www)\\." : "^(www|mobile|m)\\."

      if let range = host.range(of: textToReplace, options: .regularExpression) {
        host.replaceSubrange(range, with: "")
      }

      return host
    }

    /**
     Returns the base domain from a given hostname. The base domain name is defined as the public domain suffix
     with the base private domain attached to the front. For example, for the URL www.bbc.co.uk, the base domain
     would be bbc.co.uk. The base domain includes the public suffix (co.uk) + one level down (bbc).
     
     :returns: The base domain string for the given host name.
     */
    public var baseDomain: String? {
        //      guard !isIPv6, let host = host else { return nil }
        guard let host = host else { return nil }
        
        // If this is just a hostname and not a FQDN, use the entire hostname.
        if !host.contains(".") {
            return host
        }
        return nil
        
    }
    
    /**
     * Returns just the domain, but with the same scheme.
     *
     * E.g., https://m.foo.com/bar/baz?noo=abc#123  => https://foo.com
     *
     * Any failure? Return this URL.
     */
    public var domainURL: URL {
        if let normalized = self.normalizedHost() {
            // Use URLComponents instead of URL since the former correctly preserves
            // brackets for IPv6 hosts, whereas the latter escapes them.
            var components = URLComponents()
            components.scheme = self.scheme
            components.port = self.port
            components.host = normalized
            return components.url ?? self
        }
        
        return self
    }
}
