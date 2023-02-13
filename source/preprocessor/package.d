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
private enum IfDefDirective = "ifdef";
private enum IfNDefDirective = "ifndef";
private enum ElseDirective = "else";
private enum EndIfDirective = "endif";

private static const string[] conditionalTerminators = [
    ElseDirective, EndIfDirective
];

/** 
 * A context containing information regarding the build process,
 * such a source files.
 */
struct BuildContext {
    /// Sources to be processed
    SourceMap sources;

    /** 
     * When specified, only these sources will be processed.
     * Sources specified in "sources" will still be able to be included
     * and processed, but are treated as libraries.
     * When empty, all sources in "sources" will be processed.
     */
    SourceMap mainSources;

    /// A map of pre-defined definitions use in conditionals.
    string[string] definitions;

    /**
     * The maximum amount of inclusions allowed. This is to prevent 
     * an endless inclusion cycle.
     */
    uint inclusionLimit = 4000;
}

/** 
 * Result with modified source files.
 */
struct ProcessingResult {
    // The processed (main) sources.
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
    const(SourceMap) sources = context.mainSources.length > 0 ? context.mainSources
        : context.sources;
    foreach (Name name, SourceCode source; sources) {
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
    case IfDefDirective:
        processIfDefCondition(parseCtx, buildCtx);
        break;
    case IfNDefDirective:
        processIfNDefCondition(parseCtx, buildCtx);
        break;
    case EndIfDirective:
        throw new ParseException(parseCtx, "#endif directive found without accompanying starting conditional (#if/#ifdef)");
    case ElseDirective:
        throw new ParseException(parseCtx, "#else directive found outside of conditional block");
    default:
        // Ignore directive. It may be of semantic importance to the source in another way.
    }
}

private void processInclude(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    if (parseCtx.inclusions >= buildCtx.inclusionLimit) {
        throw new PreprocessException(parseCtx, parseCtx.codePos, "Inclusions has exceeded the limit of " ~
                buildCtx.inclusionLimit.to!string ~ ". Adjust BuildContext.inclusionLimit to increase.");
    }

    parseCtx.inclusions += 1;
    parseCtx.codePos -= 1;
    parseCtx.skipWhiteSpaceTillEol();
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

    parseCtx.replaceDirectiveStartToEnd(*includeSource);
}

private void processIfDefCondition(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    processConditionalDirective(parseCtx, buildCtx, false);
}

private void processIfNDefCondition(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    processConditionalDirective(parseCtx, buildCtx, true);
}

private void processConditionalDirective(ref ParseContext parseCtx, const ref BuildContext buildCtx, const bool negate) {
    auto startOfConditionalBlock = parseCtx.directiveStart;
    parseCtx.codePos -= 1;
    parseCtx.skipWhiteSpaceTillEol();

    auto condition = parseCtx.collectToken();
    bool isTrue = (condition in buildCtx.definitions) !is null;
    if (negate) {
        isTrue = !isTrue;
    }

    processConditionalBody(parseCtx, isTrue);
    processConditionalDelimiter(parseCtx, true, !isTrue);
    parseCtx.codePos = startOfConditionalBlock;
}

private void processConditionalDelimiter(ref ParseContext parseCtx, const bool allowElse, const bool applyElse) {
    const string delimiterDirective = parseCtx.collectToken();
    parseCtx.directiveStart = parseCtx.codePos - delimiterDirective.length - 2;

    if (delimiterDirective == EndIfDirective) {
        parseCtx.directiveEnd = parseCtx.codePos;
        parseCtx.replaceDirectiveStartToEnd("");
    } else if (delimiterDirective == ElseDirective) {
        if (!allowElse) {
            throw new ParseException(parseCtx, "#else directive defined multiple times. Only one #else block is allowed.");
        }

        processConditionalBody(parseCtx, applyElse);
        processConditionalDelimiter(parseCtx, false, false);
    }
}

private void processConditionalBody(ref ParseContext parseCtx, const bool applyBody) {
    if (applyBody) {
        parseCtx.directiveEnd = parseCtx.codePos;
        parseCtx.clearDirectiveStartToEnd();
        parseCtx.seekNextDirective(conditionalTerminators);
    } else {
        parseCtx.seekNextDirective(conditionalTerminators);
        parseCtx.directiveEnd = parseCtx.codePos;
        parseCtx.clearDirectiveStartToEnd();
    }
}

private void seekNextDirective(ref ParseContext parseCtx, const string[] delimitingDirectives) {
    auto nextDirective = "";
    while (!delimitingDirectives.canFind(nextDirective) && parseCtx.codePos <
        parseCtx.source.length) {
        parseCtx.seekNext('#');
        nextDirective = parseCtx.collectToken();
    }

    if (nextDirective.length == 0) {
        throw new ParseException(parseCtx, "Unexpected end of file while processing directive.");
    }

    parseCtx.codePos -= nextDirective.length + 1;
}

private void skipWhiteSpaceTillEol(ref ParseContext parseCtx) {
    parse(parseCtx, endOfLineDelims, (const char chr, out bool stop) {
        if (!whiteSpaceDelims.canFind(chr)) {
            parseCtx.codePos -= 1;
            stop = true;
        }
    });
}

private void seekNext(ref ParseContext parseCtx, const char delimiter) {
    parse(parseCtx, [delimiter], (const char chr, out bool stop) {});
}

private string collectToken(ref ParseContext parseCtx, const char[] delimiters = endTokenDelims) {
    string token;
    parse(parseCtx, delimiters, (const char chr, out bool stop) { token ~= chr; });
    return token;
}

private void parse(ref ParseContext parseCtx, void delegate(const char chr, out bool stop) func) {
    parse(parseCtx, [], func);
}

private void parse(ref ParseContext parseCtx, const char[] delimiters, void delegate(
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

void clearDirectiveStartToEnd(ref ParseContext parseCtx) {
    parseCtx.replaceDirectiveStartToEnd("");
}

void replaceDirectiveStartToEnd(ref ParseContext parseCtx, const string replacement) {
    parseCtx.source.replaceInPlace(parseCtx.directiveStart, parseCtx.directiveEnd, replacement);
    parseCtx.codePos = parseCtx.directiveStart;
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

/////// Debugging convenience functions
private void deb(string message, bool showWhitspace = false) {
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

private void deb(const ref ParseContext parseCtx, bool showWhitspace = false) {
    debpos(parseCtx, parseCtx.codePos, showWhitspace);
}

private void debpos(const ref ParseContext parseCtx, ulong pos, bool showWhitspace = false) {
    auto pre = parseCtx.source[0 .. pos];
    auto cur = parseCtx.source[pos].to!string;
    auto post = parseCtx.source[pos + 1 .. $];
    auto state = pre ~ "[" ~ cur ~ "]" ~ post;

    deb(state, showWhitspace);
}

private void debcur(const ref ParseContext parseCtx) {
    deb(parseCtx.source[parseCtx.codePos].to!string);
}
//////

// Generic tests
version (unittest) {
    @("Ignore unknown directive")
    unittest {
        auto main = "#banana rama";
        auto context = BuildContext([
                "main.txt": main
            ]);

        auto result = preprocess(context).sources["main.txt"];
        assert(result == main);
    }

    @("Only process specified set of main sources")
    unittest {
        auto main = "#include <libby>";
        auto libby = "#include <roses>";
        auto roses = "Roses";

        BuildContext context;
        context.sources = [
            "libby": libby,
            "roses": roses
        ];
        context.mainSources = [
            "main": main
        ];

        auto result = preprocess(context).sources;
        assert(result["main"] == roses);
    }
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

// Conditional tests
version (unittest) {
    import std.exception : assertThrown;
    import std.string : strip;

    @("Fail if a rogue #endif is found")
    unittest {
        auto main = "#endif";
        auto context = BuildContext(["main": main]);

        assertThrown!ParseException(preprocess(context));
    }

    @("Fail if a rogue #else is found")
    unittest {
        auto main = "#else";
        auto context = BuildContext(["main": main]);

        assertThrown!ParseException(preprocess(context));
    }

    @("Include body if token is defined")
    unittest {
        auto main = "
            #ifdef I_AM_GROOT
            Groot!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = [
            "I_AM_GROOT": "very"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Groot!");
    }

    @("Not include body if token is not defined")
    unittest {
        auto main = "
            #ifdef I_AM_NOT_GROOT
            Groot!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = [
            "I_AM_GROOT": "very"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "");
    }

    @("Include else body if token is not defined")
    unittest {
        auto main = "
            #ifdef I_AM_NOT_GROOT
            Groot!
            #else
            Not Groot!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = [
            "I_AM_GROOT": "very"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Not Groot!");
    }

    @("Not include else body if token is defined")
    unittest {
        auto main = "
            #ifdef I_AM_GROOT
            Tree!
            #else
            Not Tree!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = [
            "I_AM_GROOT": "very"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Tree!");
    }

    @("Fail when else is defined multiple times")
    unittest {
        auto main = "
            #ifdef I_AM_NOT_GROOT
            Groot!
            #else
            Not Groot!
            #else
            Still not Groot!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        assertThrown!ParseException(preprocess(context));
    }

    @("Fail when end of file is reached before conditional terminator")
    unittest {
        auto main = "
            #ifdef I_AM_GROOT
            Groot!
        ";

        auto context = BuildContext(["main": main]);
        assertThrown!ParseException(preprocess(context));
    }

    @("Include body if token is not defined in ifndef")
    unittest {
        auto main = "
            #ifndef I_AM_NOT_GROOT
            Groot not here!
            #endif
        ";

        auto context = BuildContext(["main": main]);

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Groot not here!");
    }

    @("Not include body if token is defined in ifndef")
    unittest {
        auto main = "
            #ifndef I_AM_NOT_GROOT
            Groot not here!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = ["I_AM_NOT_GROOT": "ok man!"];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "");
    }

    @("Include else body if token is defined in ifndef")
    unittest {
        auto main = "
            #ifndef I_AM_NOT_GROOT
            Groot not here!
            #else
            Big tree thing is here!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.definitions = ["I_AM_NOT_GROOT": "ok man!"];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Big tree thing is here!");
    }

    @("Not include else body if token is not defined in ifndef")
    unittest {
        auto main = "
            #ifndef I_AM_NOT_GROOT
            Groot not here!
            #else
            Big tree thing is here!
            #endif
        ";

        auto context = BuildContext(["main": main]);

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Groot not here!");
    }

    @("#Include works in conditional body")
    unittest {
        import std.string : replace;

        auto one = "One";
        auto eins = "EINS";
        auto two = "Two";
        auto zwei = "ZWEI";
        auto three = "Three";
        auto drei = "DREI";
        auto four = "Four";
        auto vier = "VIER";

        auto main = "
            #ifdef ONE
                #include <one>
            #else
                #include <eins>
            #endif
            #ifdef ZWEI
                #include <zwei>
            #else
                #include <two>
            #endif
            #ifndef DREI
                #include <three>
            #else
                #include <drei>
            #endif
            #ifndef FOUR
                #include <vier>
            #else
                #include <four>
            #endif
        ";

        BuildContext context;
        context.definitions = [
            "ONE": "",
            "FOUR": "",
        ];
        context.sources = [
            "one": one,
            "eins": eins,
            "two": two,
            "zwei": zwei,
            "three": three,
            "drei": drei,
            "four": four,
            "vier": vier
        ];
        context.mainSources = ["main": main];

        auto result = preprocess(context).sources;
        auto actual = result["main"].replace(' ', "").replace('\n', "");
        assert(actual == "OneTwoThreeFour");
    }

    @("Conditionals inside of conditional is not supported")
    unittest {
        auto main = "
            #ifdef HI
                #ifdef REALLY_HI
                    Hi!
                #endif
            #endif
        ";

        auto context = BuildContext(["main": main]);

        assertThrown!ParseException(preprocess(context));
    }

    @("Conditionals inside of included code is supported")
    unittest {
        auto main = "
            #ifdef HI
                #include <include>
            #endif
        ";

        auto include = "
            #ifdef REALLY_HI
                Hi!
            #endif
        ";

        auto context = BuildContext();
        context.sources = [
            "include": include
        ];
        context.mainSources = [
            "main": main
        ];
        context.definitions = [
            "HI": null,
            "REALLY_HI": null
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Hi!");
    }

    //TODO: define/undef
    //TODO: if/elseif
    //TODO: error
    //TODO: #pragma once
}
