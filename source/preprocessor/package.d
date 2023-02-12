/**
 * A language-agnostic C-like pre-processor.
 * Only UTF-8 text is supported.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor;

import std.algorithm : canFind;
import std.conv : to;
import std.array : replaceInPlace;
import std.path : dirName;

alias SourceCode = string;
alias Name = string;
alias SourceMap = SourceCode[Name];

private enum DirectiveStart = '#';
private static const char[] endOfLineDelims = ['\n', '\r'];
private static const char[] endTokenDelims = [' ', '\t', '\n', '\r'];
private static const char[] whiteSpaceDelims = [' ', '\t'];

private enum IncludeDirective = "include";

/** 
 * A context containing information regarding the build process,
 * such a source files.
 */
struct BuildContext {
    // Sources to be processed
    SourceMap sources;

    // The maximum amount of inclusions allowed. This is to prevent 
    // an endless inclusion cycle.
    uint inclusionLimit = 4000;
}

/** 
 * Result with modified source files.
 */
struct ProcessingResult {
    SourceMap sources;
}

private struct ParseContext {
    string name;
    SourceCode source;

    ulong codePos;
    ulong directiveStart;
    ulong directiveEnd;
    string directive;
    uint inclusions;
}

/** 
 * An exception typically thrown when there are parsing errors while preprocessing.
 */
class ParseException : Exception {
    this(in ref ParseContext parseCtx, string msg, string file = __FILE__, size_t line = __LINE__) {
        ulong srcLine;
        ulong srcColumn;
        calculateLineColumn(parseCtx, srcLine, srcColumn);
        auto parseErrorMsg = "Error parsing " ~ parseCtx.name ~ "(" ~ srcLine.to!string ~ "," ~ srcColumn.to!string ~ "): " ~ msg;
        super(parseErrorMsg, file, line);
    }
}

/** 
 * An exception thrown when something fails while preprocessing.
 * Except for parsing errors, they will be thrown as a ParseException.
 */
class PreprocessException : Exception {
    this(in ref ParseContext parseCtx, ulong codePos, string msg, string file = __FILE__, size_t line = __LINE__) {
        ulong srcLine;
        ulong srcColumn;
        calculateLineColumn(parseCtx, codePos, srcLine, srcColumn);
        auto parseErrorMsg = "Error processing " ~ parseCtx.name ~ "(" ~ srcLine.to!string ~ "," ~ srcColumn
            .to!string ~ "): " ~ msg;
        super(parseErrorMsg, file, line);
    }
}

ProcessingResult preprocess(const ref BuildContext context) {
    ProcessingResult result;
    foreach (Name name, SourceCode source; context.sources) {
        result.sources[name] = processFile(name, source, context);
    }

    return result;
}

private SourceCode processFile(const Name name, const ref SourceCode source, const ref BuildContext buildCtx) {
    auto parseCtx = ParseContext(name, source);
    parse(parseCtx, (const char chr, out bool stop) {
        if (chr == DirectiveStart) {
            parseCtx.directiveStart = parseCtx.codePos - 1;
            parseCtx.directive = collectToken(parseCtx);
            processDirective(parseCtx, buildCtx);

            parseCtx.directive = "";
            parseCtx.directiveStart = 0;
            parseCtx.directiveEnd = 0;
        }
    });

    return parseCtx.source;
}

private void processDirective(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    switch (parseCtx.directive) {
    case IncludeDirective:
        processInclude(parseCtx, buildCtx);
        break;
    default:
        // Ignore directive. It may be of semantic importance to the source in another way.
    }
}

private void processInclude(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    if (parseCtx.inclusions >= buildCtx.inclusionLimit) {
        throw new PreprocessException(parseCtx, parseCtx.codePos, "Inclusions has exceeded the limit of " ~
                buildCtx.inclusionLimit.to!string);
    }

    parseCtx.inclusions += 1;
    parseCtx.codePos -= 1;
    skipWhiteSpaceTillEol(parseCtx);
    char startChr = parseCtx.source[parseCtx.codePos];
    bool absoluteInclusion;
    if (startChr == '"') {
        absoluteInclusion = false;
    } else if (startChr == '<') {
        absoluteInclusion = true;
    } else {
        throw new ParseException(parseCtx, "Failed to parse include directive: Expected \" or <.");
    }

    parseCtx.codePos += 1;
    const string includeName = collectToken(parseCtx, ['"', '>']);
    parseCtx.directiveEnd = parseCtx.codePos;

    auto includeSource = includeName in buildCtx.sources;
    if (includeSource is null && !absoluteInclusion) {
        string currentDir = parseCtx.name.dirName;
        includeSource = currentDir ~ "/" ~ includeName in buildCtx.sources;
    }

    if (includeSource is null) {
        throw new PreprocessException(parseCtx, parseCtx.directiveStart, "Failed to include '" ~ includeName ~ "': It does not exist.");
    }

    parseCtx.source.replaceInPlace(parseCtx.directiveStart, parseCtx.directiveEnd, *includeSource);
    parseCtx.codePos = parseCtx.directiveStart;
}

private void skipWhiteSpaceTillEol(ref ParseContext parseCtx) {
    parse(parseCtx, endOfLineDelims, (const char chr, out bool stop) {
        if (!whiteSpaceDelims.canFind(chr)) {
            parseCtx.codePos -= 1;
            stop = true;
        }
    });
}

private string collectToken(ref ParseContext parseCtx, const char[] delimiters = endTokenDelims) {
    string token;
    parse(parseCtx, delimiters, (const char chr, out bool stop) { token ~= chr; });
    return token;
}

private void parse(ref ParseContext parseCtx, void delegate(const char, out bool stop) func) {
    parse(parseCtx, [], func);
}

private void parse(ref ParseContext parseCtx, const char[] delimiters, void delegate(
        const char, out bool stop) func) {
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

private void calculateLineColumn(const ref ParseContext parseCtx, out ulong line, out ulong column) {
    calculateLineColumn(parseCtx, parseCtx.codePos, line, column);
}

private void calculateLineColumn(const ref ParseContext parseCtx, in ulong codePos, out ulong line, out ulong column) {
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

// temp
private void deb(string message) {
    import std.stdio;

    writeln(message);
}

// Includes tests
version (unittest) {
    import std.exception : assertThrown;

    @("Resolve includes")
    unittest {
        auto hi = "Hi!";
        auto main = "#include <hi.txt>";
        auto context = BuildContext([
                "hi.txt": hi,
                "main.txt": main
            ]);

        auto result = preprocess(context);

        assert(result.sources["hi.txt"] == hi);
        assert(result.sources["main.txt"] == hi);
    }

    @("Resolve multiple includes")
    unittest {
        auto hi = "Hi!";
        auto howAreYou = "How are you?";
        auto main = "
            #include <hi.txt>
            #include <howAreYou.txt>
        ";

        auto context = BuildContext([
            "hi.txt": hi,
            "howAreYou.txt": howAreYou,
            "main.txt": main
        ]);

        auto result = preprocess(context);

        auto expectedResult = "
            Hi!
            How are you?
        ";

        assert(result.sources["hi.txt"] == hi);
        assert(result.sources["howAreYou.txt"] == howAreYou);
        assert(result.sources["main.txt"] == expectedResult);
    }

    @("Resolve includes in includes")
    unittest {
        auto hi = "Hi!";
        auto secondary = "#include <hi.txt>";
        auto main = "#include <secondary.txt>";

        auto context = BuildContext([
            "hi.txt": hi,
            "secondary.txt": secondary,
            "main.txt": main
        ]);

        auto result = preprocess(context);

        assert(result.sources["hi.txt"] == hi);
        assert(result.sources["secondary.txt"] == hi);
        assert(result.sources["main.txt"] == hi);
    }

    @("Fail to include when filename is on other line")
    unittest {
        auto main = "
            #include
            <other.txt>
        ";

        auto context = BuildContext([
                "main.txt": main
            ]);

        assertThrown!ParseException(preprocess(context));
    }

    @("Fail to include when filename does not start with quote or <")
    unittest {
        auto main = "#include 'coolfile.c'";
        auto context = BuildContext([
                "main.txt": main
            ]);

        assertThrown!ParseException(preprocess(context));
    }

    @("Fail to include when filename does not start with quote or <")
    unittest {
        auto main = "#include <notfound.404>";
        auto context = BuildContext([
                "main.txt": main
            ]);

        assertThrown!PreprocessException(preprocess(context));
    }

    @("Ignore unknown directive")
    unittest {
        auto main = "#banana rama";
        auto context = BuildContext([
                "main.txt": main
            ]);

        auto result = preprocess(context).sources["main.txt"];
        assert(result == main);
    }

    @("Prevent endless inclusion cycle")
    unittest {
        auto main = "#include \"main.txt\"";
        auto context = BuildContext([
                "main.txt": main
            ]);
        context.inclusionLimit = 5;

        assertThrown!PreprocessException(preprocess(context));
    }

    @("Inclusions using quotes are directory-aware and relative")
    unittest {
        auto main = "#include \"secondary.txt\"";
        auto secondary = "Heey";
        auto context = BuildContext([
            "cool/main.txt": main,
            "cool/secondary.txt": secondary
        ]);

        auto result = preprocess(context);

        assert(result.sources["cool/main.txt"] == secondary);
        assert(result.sources["cool/secondary.txt"] == secondary);
    }
}
