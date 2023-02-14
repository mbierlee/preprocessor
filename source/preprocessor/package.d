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
import std.string : toLower, startsWith, endsWith;

alias SourceCode = string;
alias Name = string;
alias SourceMap = SourceCode[Name];

private enum DirectiveStart = '#';
private enum MacroStartEnd = '_';
private static const char[] endOfLineDelims = ['\n', '\r'];
private static const char[] endTokenDelims = [' ', '\t', '\n', '\r'];
private static const char[] whiteSpaceDelims = [' ', '\t'];

private enum IncludeDirective = "include";
private enum IfDirective = "if";
private enum IfDefDirective = "ifdef";
private enum IfNDefDirective = "ifndef";
private enum ElsIfDirective = "elsif";
private enum ElseDirective = "else";
private enum EndIfDirective = "endif";

private static const string[] conditionalTerminators = [
    ElsIfDirective, ElseDirective, EndIfDirective
];

private enum FileMacro = "FILE";
private enum LineMacro = "LINE";

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

    /**
     * A map of pre-defined macros. 
     * Built-in macros will override these.
     */
    string[string] macros;

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
    string[string] macros;

    ulong codePos;
    ulong replaceStart;
    ulong replaceEnd;
    string directive;
    uint inclusions;
}

/** 
 * An exception typically thrown when there are parsing errors while preprocessing.
 */
class ParseException : PreprocessException {
    this(in ref ParseContext parseCtx, string msg, string file = __FILE__, size_t line = __LINE__) {
        auto errorMessage = "Parse error: " ~ msg;
        super(parseCtx, parseCtx.codePos, errorMessage, file, line);
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

/** 
 * Preprocess the sources contained in the given build context.
 * Params:
 *   context = Context used in the pre-processing run.
 * Returns: A procesing result containing all processed (main) sources.
 */
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
    string[string] builtInMacros = [
        FileMacro: name,
        LineMacro: "0"
    ];

    string[string] macros = cast(string[string]) buildCtx.macros.dup;
    foreach (string macroName, string macroValue; builtInMacros) {
        macros[macroName] = macroValue;
    }

    auto parseCtx = ParseContext(name, source, macros);
    bool foundMacroTokenBefore = false;
    parse(parseCtx, (const char chr, out bool stop) {
        if (chr == DirectiveStart) {
            foundMacroTokenBefore = false;
            parseCtx.replaceStart = parseCtx.codePos - 1;
            parseCtx.directive = collectToken(parseCtx);
            processDirective(parseCtx, buildCtx);

            parseCtx.directive = "";
            parseCtx.replaceStart = 0;
            parseCtx.replaceEnd = 0;
        } else if (chr == MacroStartEnd) {
            if (foundMacroTokenBefore) {
                expandMacro(parseCtx);
                foundMacroTokenBefore = false;
            } else {
                foundMacroTokenBefore = true;
            }
        } else {
            foundMacroTokenBefore = false;
        }

    });

    return parseCtx.source;
}

private void processDirective(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    switch (parseCtx.directive) {
    case IncludeDirective:
        processInclude(parseCtx, buildCtx);
        break;
    case IfDirective:
        processIfCondition(parseCtx);
        break;
    case IfDefDirective:
        processIfDefCondition(parseCtx);
        break;
    case IfNDefDirective:
        processIfNDefCondition(parseCtx);
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
    parseCtx.replaceEnd = parseCtx.codePos;

    auto includeSource = includeName in buildCtx.sources;
    if (includeSource is null && !absoluteInclusion) {
        string currentDir = parseCtx.name.dirName;
        includeSource = currentDir ~ "/" ~ includeName in buildCtx.sources;
    }

    if (includeSource is null) {
        throw new PreprocessException(parseCtx, parseCtx.replaceStart, "Failed to include '" ~ includeName ~ "': It does not exist.");
    }

    parseCtx.replaceStartToEnd(*includeSource);
}

private void processIfCondition(ref ParseContext parseCtx) {
    processConditionalDirective(parseCtx, false, false);
}

private void processIfDefCondition(ref ParseContext parseCtx) {
    processConditionalDirective(parseCtx, false, true);
}

private void processIfNDefCondition(ref ParseContext parseCtx) {
    processConditionalDirective(parseCtx, true, true);
}

private void processConditionalDirective(ref ParseContext parseCtx, const bool negate, const bool onlyCheckExistence) {
    auto startOfConditionalBlock = parseCtx.replaceStart;
    parseCtx.codePos -= 1;
    parseCtx.skipWhiteSpaceTillEol();

    enum StartIfBlockDirective = "startif"; // or ifdef/ifndef
    auto conditionalDirective = StartIfBlockDirective;
    bool acceptedBody = false;
    bool processedElse = false;
    while (conditionalDirective != EndIfDirective) {
        if (conditionalDirective == StartIfBlockDirective || conditionalDirective == ElsIfDirective) {
            bool isTrue = evaluateCondition(parseCtx, negate, onlyCheckExistence);
            if (isTrue && !acceptedBody) {
                parseCtx.acceptConditionalBody();
                acceptedBody = true;
            } else {
                parseCtx.rejectConditionalBody();
            }
        } else if (conditionalDirective == ElseDirective) {
            if (processedElse) {
                throw new ParseException(parseCtx, "#else directive defined multiple times. Only one #else block is allowed.");
            }

            if (acceptedBody) {
                parseCtx.rejectConditionalBody();
            } else {
                parseCtx.acceptConditionalBody();
            }

            processedElse = true;
        }

        parseCtx.replaceStart = parseCtx.codePos - 1;
        conditionalDirective = parseCtx.collectToken();
    }

    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();

    parseCtx.codePos = startOfConditionalBlock;
}

private bool evaluateCondition(ref ParseContext parseCtx, const bool negate, const bool onlyCheckExistence) {
    auto expression = parseCtx.collectToken();
    if (expression.startsWith("__") && expression.endsWith("__")) {
        expression = expression[2 .. $ - 2];
    }

    auto macroValue = expression in parseCtx.macros;
    bool isTrue = macroValue !is null;
    if (!onlyCheckExistence) {
        isTrue = isTrue && *macroValue != "0" && *macroValue != null
            && (*macroValue).toLower != "false";
    }

    if (negate) {
        isTrue = !isTrue;
    }

    return isTrue;
}

private void acceptConditionalBody(ref ParseContext parseCtx) {
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
    parseCtx.seekNextDirective(conditionalTerminators);
}

private void rejectConditionalBody(ref ParseContext parseCtx) {
    parseCtx.seekNextDirective(conditionalTerminators);
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
}

private void expandMacro(ref ParseContext parseCtx) {
    auto macroStart = parseCtx.codePos - 2;
    auto macroName = parseCtx.collectToken([MacroStartEnd]);
    auto macroEnd = parseCtx.codePos;
    if (parseCtx.peek == MacroStartEnd) {
        macroEnd += 1;
    }

    string macroValue;
    if (macroName == LineMacro) {
        ulong line, column;
        calculateLineColumn(parseCtx, line, column);
        macroValue = line.to!string;
    } else {
        auto macroValuePtr = macroName in parseCtx.macros;
        if (macroValuePtr is null) {
            throw new ParseException(parseCtx, "Cannot expand macro __" ~ macroName ~ "__, it is undefined.");
        }

        macroValue = *macroValuePtr;
    }

    parseCtx.source.replaceInPlace(macroStart, macroEnd, macroValue);
    parseCtx.codePos = macroStart + macroValue.length;
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

private char peek(const ref ParseContext parseCtx) {
    return parseCtx.source[parseCtx.codePos];
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

void clearStartToEnd(ref ParseContext parseCtx) {
    parseCtx.replaceStartToEnd("");
}

void replaceStartToEnd(ref ParseContext parseCtx, const string replacement) {
    parseCtx.source.replaceInPlace(parseCtx.replaceStart, parseCtx.replaceEnd, replacement);
    parseCtx.codePos = parseCtx.replaceStart;
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

private void debpeek(const ref ParseContext parseCtx) {
    deb(parseCtx.peek.to!string);
}
//////
version (unittest) {
    import std.exception : assertThrown;
    import std.string : strip;
    import std.array : replace;

    string stripAllWhiteSpace(string input) {
        return input.replace(' ', "").replace('\n', "");
    }
}

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
        context.macros = [
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
        context.macros = [
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
        context.macros = [
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
        context.macros = [
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
        context.macros = ["I_AM_NOT_GROOT": "ok man!"];

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
        context.macros = ["I_AM_NOT_GROOT": "ok man!"];

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
        context.macros = [
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
        assert(result["main"].stripAllWhiteSpace == "OneTwoThreeFour");
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

        BuildContext context;
        context.sources = [
            "include": include
        ];
        context.mainSources = [
            "main": main
        ];
        context.macros = [
            "HI": null,
            "REALLY_HI": null
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Hi!");
    }

    @("Include body in if block")
    unittest {
        auto main = "
            #if HOUSE_ON_FIRE
                oh no!
            #endif
            #if FIREMAN_IN_SIGHT
                yay saved!
            #endif
            #if WATER_BUCKET_IN_HAND
                Quick use it!
            #endif
            #if LAKE_NEARBY
                Throw house in it!
            #endif
            #if CAR_NEARBY
                Book it!
            #endif
            #if SCREAM
                AAAAAAAH!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = [
            "HOUSE_ON_FIRE": "true",
            "WATER_BUCKET_IN_HAND": "0",
            "LAKE_NEARBY": "FALSE",
            "CAR_NEARBY": null,
            "SCREAM": "AAAAAAAAAAAAH!"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].stripAllWhiteSpace == "ohno!AAAAAAAH!");
    }

    @("Include else body in if block if false")
    unittest {
        auto main = "
            #if MOON
                It's a moon
            #else
                That's no moon, it's a space station!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = [
            "MOON": "false",
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "That's no moon, it's a space station!");
    }

    @("Include elseif body in if block if else if is true")
    unittest {
        auto main = "
            #if MOON
                It's a moon
            #elsif EARTH
                Oh it's just earth.
            #elsif FIRE
                We're doing captain planet stuff now?
            #else
                That's no moon, it's a space station!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = [
            "MOON": "false",
            "EARTH": "probably",
            "FIRE": "true"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Oh it's just earth.");
    }

    @("Include if body only in if block if it is true")
    unittest {
        auto main = "
            #if JA
                Ja!
            #elsif JA
                Ja!
            #else
                Nee!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = [
            "JA": "ja!",
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Ja!");
    }
}

// Macros tests
version (unittest) {
    @("Undefined macro fails to expand")
    unittest {
        auto main = "
            __MOTOR__
        ";

        auto context = BuildContext(["main.c": main]);
        assertThrown!ParseException(preprocess(context));
    }

    @("Expand custom pre-defined macro")
    unittest {
        auto main = "
            #ifdef HI
                __HI__
            #endif
            #ifdef __THERE__
                __THERE__
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = [
            "HI": "Hi",
            "THERE": "There"
        ];

        auto result = preprocess(context).sources;
        assert(result["main"].stripAllWhiteSpace == "HiThere");
    }

    @("Built-in macro __FILE__ is defined")
    unittest {
        auto main = "
            #ifdef __FILE__
                __FILE__
            #endif
        ";

        auto context = BuildContext(["main.c": main]);
        auto result = preprocess(context).sources;
        assert(result["main.c"].strip == "main.c");
    }

    @("Built-in macro __LINE__ is defined")
    unittest {
        auto main = "
            #ifdef __LINE__
                __LINE__
            #endif
        ";

        auto context = BuildContext(["main.c": main]);
        auto result = preprocess(context).sources;
        assert(result["main.c"].strip == "1"); // Code re-writing messes line numbers all up.... It truely is like a C-compiler!
    }

    @("Ignore detached second underscore as part of possible macro")
    unittest {
        auto main = "IM_AM_NOT_A_MACRO";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"] == "IM_AM_NOT_A_MACRO");
    }

    //TODO
    // __DATE__
    // __TIME__
    // __TIMESTAMP__
}

//TODO: define/undef
//TODO: error
//TODO: #pragma once
//TODO: conditionals in conditionals?
