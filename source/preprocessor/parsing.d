/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor.parsing;

import preprocessor.artifacts : ParseException, MacroMap;
import preprocessor.debugging;

import std.algorithm : canFind;
import std.array : replaceInPlace;
import std.string : endsWith;

package enum DirectiveStart = '#';
package enum MacroStartEnd = '_';
package static const char[] endOfLineDelims = ['\n', '\r'];
package static const char[] whiteSpaceDelims = [' ', '\t'];
package static const char[] endTokenDelims = endOfLineDelims ~ whiteSpaceDelims;

package struct ParseContext {
    string name;
    string source;
    MacroMap macros;

    ulong codePos;
    ulong replaceStart;
    ulong replaceEnd;
    string directive;
    uint inclusionDepth;
    string[] guardedInclusions;
}

package void skipWhiteSpaceTillEol(ref ParseContext parseCtx) {
    parse(parseCtx, endOfLineDelims, (const char chr, out bool stop) {
        if (!whiteSpaceDelims.canFind(chr)) {
            parseCtx.codePos -= 1;
            stop = true;
        }
    });
}

package void seekNext(ref ParseContext parseCtx, const char delimiter) {
    parse(parseCtx, [delimiter], (const char chr, out bool stop) {});
}

package char peek(const ref ParseContext parseCtx) {
    return parseCtx.source[parseCtx.codePos];
}

package char peekLast(const ref ParseContext parseCtx) {
    return parseCtx.source[parseCtx.codePos - 1];
}

package string collect(ref ParseContext parseCtx, const char[] delimiters = endTokenDelims) {
    string value;
    parse(parseCtx, delimiters, (const char chr, out bool stop) { value ~= chr; });
    return value;
}

package string collectTillString(ref ParseContext parseCtx, const string delimiter) {
    string value;
    parse(parseCtx, (const char chr, out bool stop) {
        value ~= chr;
        if (value.endsWith(delimiter)) {
            stop = true;
            value = value[0 .. $ - delimiter.length];
        }
    });

    return value;
}

package void parse(ref ParseContext parseCtx, void delegate(const char chr, out bool stop) func) {
    parse(parseCtx, [], func);
}

package void parse(ref ParseContext parseCtx, const char[] delimiters, void delegate(
        const char chr, out bool stop) func) {
    while (parseCtx.codePos < parseCtx.source.length) {
        const char chr = parseCtx.source[parseCtx.codePos++];
        if (delimiters.canFind(chr)) {
            break;
        }

        bool stop;
        func(chr, stop);

        if (stop) {
            break;
        }
    }
}

package void seekNextDirective(ref ParseContext parseCtx, const string[] delimitingDirectives) {
    auto nextDirective = "";
    while (!delimitingDirectives.canFind(nextDirective) && parseCtx.codePos <
        parseCtx.source.length) {
        parseCtx.seekNext('#');
        nextDirective = parseCtx.collect();
    }

    if (nextDirective.length == 0) {
        throw new ParseException(parseCtx, "Unexpected end of file while processing directive.");
    }

    parseCtx.codePos -= nextDirective.length + 1;
}

void clearStartToEnd(ref ParseContext parseCtx) {
    parseCtx.replaceStartToEnd("");
}

void replaceStartToEnd(ref ParseContext parseCtx, const string replacement) {
    parseCtx.source.replaceInPlace(parseCtx.replaceStart, parseCtx.replaceEnd, replacement);
    parseCtx.codePos = parseCtx.replaceStart + replacement.length;
}

package void calculateLineColumn(const ref ParseContext parseCtx, out ulong line, out ulong column) {
    calculateLineColumn(parseCtx, parseCtx.codePos, line, column);
}

package void calculateLineColumn(const ref ParseContext parseCtx, in ulong codePos, out ulong line, out ulong column) {
    foreach (size_t idx, char chr; parseCtx.source) {
        if (idx == codePos) {
            break;
        }

        if (chr == '\n') {
            line += 1;
            column = 0;
        }

        column += 1;
    }
}
