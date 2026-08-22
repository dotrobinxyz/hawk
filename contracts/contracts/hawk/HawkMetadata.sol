//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMetadataService} from "../wrapper/IMetadataService.sol";
import {PARENT_CANNOT_CONTROL, CANNOT_UNWRAP} from "../wrapper/INameWrapper.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IHawkTokenURIProvider} from "./IHawkTokenURIProvider.sol";
import {HawkBaseRegistrar} from "./HawkBaseRegistrar.sol";
import {HawkWrapper} from "./HawkWrapper.sol";

/// @title HawkMetadata
/// @notice Fully on-chain metadata for Hawk names: JSON + SVG rendered from
///         contract state, served as data: URIs. No metadata server, no
///         external dependency — the art lives in the contract and renders on
///         any marketplace.
///
///         Serves both collections:
///         - `tokenURI721(id)` for the ERC-721 base registrar
///           (id = uint256(labelhash); label read from the registrar).
///         - `uri(id)` (IMetadataService) for the ERC-1155 wrapper
///           (id = uint256(namehash); name read from the wrapper's DNS-encoded
///           `names` mapping).
///
/// @dev New contract, no upstream counterpart (upstream uses an off-chain
///      metadata service). View-only: it reads registrar/wrapper state and
///      renders; it holds no state of its own and can be swapped by the
///      registrar/wrapper owner without touching registration state.
contract HawkMetadata is IMetadataService, IHawkTokenURIProvider {
    using StringUtils for *;

    HawkBaseRegistrar public immutable registrar;
    HawkWrapper public immutable wrapper;

    string private constant BG = "#0A0E1A";
    string private constant FG = "#F4F6FA";
    string private constant ACCENT = "#37C6B4"; // hawk-egg
    string private constant MUTED = "#5B6B84";

    constructor(HawkBaseRegistrar _registrar, HawkWrapper _wrapper) {
        registrar = _registrar;
        wrapper = _wrapper;
    }

    // ------------------------------------------------------------------
    // ERC-721 (base registrar)
    // ------------------------------------------------------------------

    /// @inheritdoc IHawkTokenURIProvider
    function tokenURI721(uint256 id) external view returns (string memory) {
        string memory label = registrar.labels(id);
        uint256 expiry = registrar.nameExpires(id);

        string memory display;
        uint256 len;
        if (bytes(label).length == 0) {
            // Registered without a recorded label (e.g. a future controller
            // using plain `register`): fall back to the labelhash.
            display = string.concat("[", _shortHex(bytes32(id)), "].hawk");
            len = 0;
        } else {
            display = string.concat(label, ".hawk");
            len = label.strlen();
        }

        string memory badge = _lifecycleBadge(expiry, registrar.GRACE_PERIOD());

        return
            _buildURI(
                display,
                len,
                expiry,
                badge,
                "Name",
                false
            );
    }

    /// @inheritdoc IHawkTokenURIProvider
    function contractURI() external pure returns (string memory) {
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        _svgOpen(),
                        _svgMark(),
                        "<text x=\"80\" y=\"870\" font-family=\"",
                        _fontStack(),
                        "\" font-size=\"112\" font-weight=\"600\" fill=\"",
                        FG,
                        "\">hawk</text>",
                        "</svg>"
                    )
                )
            )
        );
        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        string.concat(
                            "{\"name\":\"Hawk Names\",\"description\":\"Hawk names on Base. Human-readable names with annual renewals, standards-compliant resolution, and tradeable subdomains.\",\"image\":\"",
                            image,
                            "\"}"
                        )
                    )
                )
            );
    }

    // ------------------------------------------------------------------
    // ERC-1155 (wrapper)
    // ------------------------------------------------------------------

    /// @inheritdoc IMetadataService
    function uri(uint256 id) external view returns (string memory) {
        bytes memory dnsName = wrapper.names(bytes32(id));
        (, uint32 fuses, uint64 wrapperExpiry) = wrapper.getData(id);

        (string memory display, string memory firstLabel, uint256 labelCount, bool ok) = _decodeDNS(dnsName);

        if (!ok || labelCount == 0) {
            display = string.concat("[", _shortHex(bytes32(id)), "]");
            return _buildURI(display, 0, 0, "", "Wrapped Name", true);
        }

        bool is2LD = labelCount == 2;
        uint256 expiry;
        string memory badge;
        if (is2LD) {
            // For .hawk second-level names the wrapper stores expiry + grace;
            // display the registrar's expiry, which is the meaningful date.
            expiry = registrar.nameExpires(
                uint256(keccak256(bytes(firstLabel)))
            );
            badge = _lifecycleBadge(expiry, registrar.GRACE_PERIOD());
        } else {
            expiry = wrapperExpiry == type(uint64).max ? 0 : wrapperExpiry;
            if (expiry != 0 && block.timestamp > expiry) {
                badge = "EXPIRED";
            }
        }

        if (bytes(badge).length == 0) {
            if (fuses & PARENT_CANNOT_CONTROL != 0) {
                badge = fuses & CANNOT_UNWRAP != 0 ? "LOCKED" : "EMANCIPATED";
            } else {
                badge = "WRAPPED";
            }
        }

        return
            _buildURI(
                display,
                firstLabel.strlen(),
                expiry,
                badge,
                is2LD ? "Wrapped Name" : "Subname",
                true
            );
    }

    // ------------------------------------------------------------------
    // JSON + SVG assembly
    // ------------------------------------------------------------------

    function _buildURI(
        string memory display,
        uint256 nameLength,
        uint256 expiry,
        string memory badge,
        string memory kind,
        bool wrapped
    ) internal view returns (string memory) {
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(_svg(display, expiry, badge)))
        );

        string memory attrs = string.concat(
            "[{\"trait_type\":\"Kind\",\"value\":\"",
            kind,
            "\"}"
        );
        if (nameLength > 0) {
            attrs = string.concat(
                attrs,
                ",{\"trait_type\":\"Length\",\"display_type\":\"number\",\"value\":",
                Strings.toString(nameLength),
                "}"
            );
        }
        if (expiry > 0) {
            attrs = string.concat(
                attrs,
                ",{\"trait_type\":\"Expiration Date\",\"display_type\":\"date\",\"value\":",
                Strings.toString(expiry),
                "}"
            );
        }
        attrs = string.concat(attrs, "]");

        string memory escaped = _escapeJSON(display);
        string memory json = string.concat(
            "{\"name\":\"",
            escaped,
            "\",\"description\":\"",
            escaped,
            wrapped
                ? ", a wrapped Hawk name on Base.\""
                : ", a Hawk name on Base.\"",
            ",\"image\":\"",
            image,
            "\",\"attributes\":",
            attrs,
            "}"
        );

        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes(json))
            );
    }

    function _svg(
        string memory display,
        uint256 expiry,
        string memory badge
    ) internal view returns (string memory) {
        // Split "a.b.hawk" into the part before the final ".hawk" and the
        // suffix, so the suffix renders in the accent colour.
        (string memory head, bool hasSuffix) = _stripHawkSuffix(display);

        // Approximate rendered width: wide (4-byte UTF-8, mostly emoji)
        // codepoints count double. Squeeze via textLength only for names too
        // long for the smallest bucket — stretching short names distorts them.
        uint256 vlen = _visualLength(display);
        uint256 fontSize = _fontSize(vlen);
        string memory fit = vlen > 28
            ? " textLength=\"840\" lengthAdjust=\"spacingAndGlyphs\""
            : "";

        string memory nameText = hasSuffix
            ? string.concat(
                "<tspan fill=\"",
                FG,
                "\">",
                _escapeXML(head),
                "</tspan><tspan fill=\"",
                ACCENT,
                "\">.hawk</tspan>"
            )
            : string.concat(
                "<tspan fill=\"",
                FG,
                "\">",
                _escapeXML(display),
                "</tspan>"
            );

        string memory expiryLine = expiry > 0
            ? string.concat(
                "<text x=\"80\" y=\"928\" font-family=\"",
                _fontStack(),
                "\" font-size=\"30\" letter-spacing=\"2\" fill=\"",
                MUTED,
                "\">EXPIRES ",
                _dateString(expiry),
                "</text>"
            )
            : "";

        string memory badgeEl = bytes(badge).length > 0
            ? string.concat(
                "<text x=\"920\" y=\"122\" text-anchor=\"end\" font-family=\"",
                _fontStack(),
                "\" font-size=\"28\" letter-spacing=\"3\" fill=\"",
                ACCENT,
                "\">",
                badge,
                "</text>"
            )
            : "";

        return
            string.concat(
                _svgOpen(),
                _svgMark(),
                badgeEl,
                "<text x=\"80\" y=\"858\" font-family=\"",
                _fontStack(),
                "\" font-size=\"",
                Strings.toString(fontSize),
                "\" font-weight=\"600\"",
                fit,
                ">",
                nameText,
                "</text>",
                expiryLine,
                "</svg>"
            );
    }

    function _svgOpen() internal pure returns (string memory) {
        return
            string.concat(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1000\" height=\"1000\" viewBox=\"0 0 1000 1000\"><rect width=\"1000\" height=\"1000\" fill=\"",
                BG,
                "\"/>"
            );
    }

    /// @dev The Hawk mark: an egg tilted slightly, top-left.
    function _svgMark() internal pure returns (string memory) {
        return
            string.concat(
                "<ellipse cx=\"114\" cy=\"118\" rx=\"34\" ry=\"44\" transform=\"rotate(12 114 118)\" fill=\"",
                ACCENT,
                "\"/>"
            );
    }

    function _fontStack() internal pure returns (string memory) {
        return "ui-sans-serif,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
    }

    function _fontSize(uint256 vlen) internal pure returns (uint256) {
        if (vlen <= 11) return 112;
        if (vlen <= 15) return 84;
        if (vlen <= 20) return 64;
        if (vlen <= 28) return 48;
        return 36;
    }

    /// @dev Codepoint count with 4-byte (wide) codepoints counted double.
    function _visualLength(
        string memory s_
    ) internal pure returns (uint256 vlen) {
        bytes memory b = bytes(s_);
        uint256 i = 0;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            if (c < 0x80) {
                i += 1;
                vlen += 1;
            } else if (c < 0xE0) {
                i += 2;
                vlen += 1;
            } else if (c < 0xF0) {
                i += 3;
                vlen += 1;
            } else {
                i += 4;
                vlen += 2;
            }
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Decodes a DNS-encoded name ("\x04hawk\x00" style) into a dotted
    ///      display string. Returns ok=false on malformed input.
    function _decodeDNS(
        bytes memory dnsName
    )
        internal
        pure
        returns (
            string memory display,
            string memory firstLabel,
            uint256 labelCount,
            bool ok
        )
    {
        uint256 i = 0;
        bytes memory out;
        while (i < dnsName.length) {
            uint256 len = uint8(dnsName[i]);
            if (len == 0) {
                return (string(out), firstLabel, labelCount, true);
            }
            i++;
            if (i + len > dnsName.length) {
                return ("", "", 0, false);
            }
            bytes memory label = new bytes(len);
            for (uint256 j = 0; j < len; j++) {
                label[j] = dnsName[i + j];
            }
            if (labelCount == 0) {
                firstLabel = string(label);
                out = label;
            } else {
                out = bytes.concat(out, ".", label);
            }
            labelCount++;
            i += len;
        }
        return ("", "", 0, false);
    }

    /// @dev Splits "x.y.hawk" into ("x.y", true); returns (display, false)
    ///      when the name doesn't end in ".hawk".
    function _stripHawkSuffix(
        string memory display
    ) internal pure returns (string memory, bool) {
        bytes memory b = bytes(display);
        bytes memory suffix = ".hawk";
        if (b.length <= suffix.length) {
            return (display, false);
        }
        for (uint256 i = 0; i < suffix.length; i++) {
            if (b[b.length - suffix.length + i] != suffix[i]) {
                return (display, false);
            }
        }
        bytes memory head = new bytes(b.length - suffix.length);
        for (uint256 i = 0; i < head.length; i++) {
            head[i] = b[i];
        }
        return (string(head), true);
    }

    function _lifecycleBadge(
        uint256 expiry,
        uint256 gracePeriod
    ) internal view returns (string memory) {
        if (expiry == 0 || block.timestamp <= expiry) {
            return "";
        }
        if (block.timestamp <= expiry + gracePeriod) {
            return "IN GRACE PERIOD";
        }
        return "EXPIRED";
    }

    function _shortHex(bytes32 value) internal pure returns (string memory) {
        bytes memory full = bytes(Strings.toHexString(uint256(value), 32));
        // 0x + first 6 + ellipsis + last 6
        bytes memory out = new bytes(2 + 6 + 3 + 6);
        for (uint256 i = 0; i < 8; i++) {
            out[i] = full[i];
        }
        out[8] = 0xE2; // UTF-8 ellipsis …
        out[9] = 0x80;
        out[10] = 0xA6;
        for (uint256 i = 0; i < 6; i++) {
            out[11 + i] = full[full.length - 6 + i];
        }
        return string(out);
    }

    /// @dev "YYYY-MM-DD" from a unix timestamp (days-from-civil inverse,
    ///      Howard Hinnant's algorithm).
    function _dateString(uint256 ts) internal pure returns (string memory) {
        uint256 z = ts / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) {
            y += 1;
        }
        return
            string.concat(
                Strings.toString(y),
                "-",
                _pad2(m),
                "-",
                _pad2(d)
            );
    }

    function _pad2(uint256 v) internal pure returns (string memory) {
        return
            v < 10
                ? string.concat("0", Strings.toString(v))
                : Strings.toString(v);
    }

    /// @dev JSON string escaping: quote, backslash, and control bytes.
    ///      Multi-byte UTF-8 passes through untouched.
    function _escapeJSON(
        string memory value
    ) internal pure returns (string memory) {
        bytes memory b = bytes(value);
        uint256 extra = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 0x22 || c == 0x5C) {
                extra += 1;
            } else if (c < 0x20) {
                extra += 5; // \u00XX
            }
        }
        if (extra == 0) {
            return value;
        }
        bytes memory out = new bytes(b.length + extra);
        uint256 k = 0;
        bytes16 hexChars = "0123456789abcdef";
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 0x22 || c == 0x5C) {
                out[k++] = "\\";
                out[k++] = b[i];
            } else if (c < 0x20) {
                out[k++] = "\\";
                out[k++] = "u";
                out[k++] = "0";
                out[k++] = "0";
                out[k++] = hexChars[c >> 4];
                out[k++] = hexChars[c & 0x0F];
            } else {
                out[k++] = b[i];
            }
        }
        return string(out);
    }

    /// @dev XML text escaping for SVG: & < > " ' escaped, control bytes
    ///      replaced with spaces. Multi-byte UTF-8 passes through untouched.
    function _escapeXML(
        string memory value
    ) internal pure returns (string memory) {
        bytes memory b = bytes(value);
        uint256 extra = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 0x26) extra += 4; // &amp;
            else if (c == 0x3C || c == 0x3E) extra += 3; // &lt; &gt;
            else if (c == 0x22) extra += 5; // &quot;
            else if (c == 0x27) extra += 4; // &#39;
        }
        if (extra == 0 && !_hasControlBytes(b)) {
            return value;
        }
        bytes memory out = new bytes(b.length + extra);
        uint256 k = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c == 0x26) {
                out[k++] = "&";
                out[k++] = "a";
                out[k++] = "m";
                out[k++] = "p";
                out[k++] = ";";
            } else if (c == 0x3C) {
                out[k++] = "&";
                out[k++] = "l";
                out[k++] = "t";
                out[k++] = ";";
            } else if (c == 0x3E) {
                out[k++] = "&";
                out[k++] = "g";
                out[k++] = "t";
                out[k++] = ";";
            } else if (c == 0x22) {
                out[k++] = "&";
                out[k++] = "q";
                out[k++] = "u";
                out[k++] = "o";
                out[k++] = "t";
                out[k++] = ";";
            } else if (c == 0x27) {
                out[k++] = "&";
                out[k++] = "#";
                out[k++] = "3";
                out[k++] = "9";
                out[k++] = ";";
            } else if (c < 0x20) {
                out[k++] = " ";
            } else {
                out[k++] = b[i];
            }
        }
        return string(out);
    }

    function _hasControlBytes(bytes memory b) internal pure returns (bool) {
        for (uint256 i = 0; i < b.length; i++) {
            if (uint8(b[i]) < 0x20) {
                return true;
            }
        }
        return false;
    }
}
