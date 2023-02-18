/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor.debugging;

import preprocessor.parsing : ParseContext, peek;

import std.conv : to;

package void deb(string message, bool showWhitspace = false) {
    if (showWhitspace) {
        import std.string : replace;

        message = message
            .replace(' ', '.')
            .replace('\n', "^\n")
            .replace('\r', "^\r");
    }

    import std.stdio;

    writeln(message);
}

package void deb(const ref ParseContext parseCtx, bool showWhitspace = false) {
    debpos(parseCtx, parseCtx.codePos, showWhitspace);
}

package void debpos(const ref ParseContext parseCtx, ulong pos, bool showWhitspace = false) {
    auto pre = parseCtx.source[0 .. pos];
    auto cur = parseCtx.source[pos].to!string;
    auto post = parseCtx.source[pos + 1 .. $];
    auto state = pre ~ "[" ~ cur ~ "]" ~ post;
    deb(state, showWhitspace);
}

package void debrange(const ref ParseContext parseCtx, ulong startPos, ulong endPos, bool showWhitspace = false) {
    auto pre = parseCtx.source[0 .. startPos];
    auto cur = parseCtx.source[startPos .. endPos];
    auto post = parseCtx.source[endPos + 1 .. $];
    auto state = pre ~ "[" ~ cur ~ "]" ~ post;
    deb(state, showWhitspace);
}

package void debpeek(const ref ParseContext parseCtx) {
    deb(parseCtx.peek.to!string);
}
