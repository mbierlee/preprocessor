/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor.processing;

import preprocessor.artifacts : BuildContext, PreprocessException, ParseException, FileMacro, LineMacro, MacroMap,
    builtInMacros;
import preprocessor.parsing : ParseContext, parse, collect, DirectiveStart, MacroStartEnd, skipWhiteSpaceTillEol, peek,
    replaceStartToEnd, clearStartToEnd, endOfLineDelims, peekLast, seekNextDirective, calculateLineColumn, seekNext,
    collectTillString;
import preprocessor.debugging;

import std.conv : to;
import std.path : dirName;
import std.algorithm : canFind;
import std.string : toLower, startsWith, endsWith, strip;
import std.array : replaceInPlace;

private enum IncludeDirective = "include";
private enum IfDirective = "if";
private enum IfDefDirective = "ifdef";
private enum IfNDefDirective = "ifndef";
private enum ElIfDirective = "elif";
private enum ElseDirective = "else";
private enum EndIfDirective = "endif";
private enum DefineDirective = "define";
private enum UndefDirective = "undef";
private enum ErrorDirective = "error";
private enum PragmaDirective = "pragma";

private enum PragmaOnceExtension = "once";

private static const string[] conditionalTerminators = [
    ElIfDirective, ElseDirective, EndIfDirective
];

package void processFile(
    const string name,
    const ref string inSource,
    const ref BuildContext buildCtx,
    ref MacroMap macros,
    ref string[] guardedInclusions,
    out string outSource,
    const uint currentInclusionDepth = 0
) {
    macros[FileMacro] = name;
    macros[LineMacro] = "true"; // For #if eval

    ParseContext parseCtx;
    parseCtx.name = name;
    parseCtx.source = inSource;
    parseCtx.macros = macros;
    parseCtx.guardedInclusions = guardedInclusions;
    parseCtx.inclusionDepth = currentInclusionDepth;

    bool foundMacroTokenBefore = false;
    parse(parseCtx, (const char chr, out bool stop) {
        if (chr == DirectiveStart) {
            foundMacroTokenBefore = false;
            parseCtx.replaceStart = parseCtx.codePos - 1;
            parseCtx.directive = parseCtx.collect();
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

    macros = parseCtx.macros;
    guardedInclusions = parseCtx.guardedInclusions;
    outSource = parseCtx.source;
}

private void processDirective(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    switch (parseCtx.directive) {
    case IncludeDirective:
        processInclude(parseCtx, buildCtx);
        break;

    case IfDirective:
    case IfDefDirective:
    case IfNDefDirective:
        processConditionalDirective(parseCtx, parseCtx.directive);
        break;

    case DefineDirective:
        processDefineDirective(parseCtx);
        break;

    case UndefDirective:
        processUndefDirective(parseCtx);
        break;

    case EndIfDirective:
        processUnexpectedConditional(parseCtx, buildCtx);
        break;

    case ElseDirective:
        processUnexpectedConditional(parseCtx, buildCtx);
        break;

    case ElIfDirective:
        processUnexpectedConditional(parseCtx, buildCtx);
        break;

    case ErrorDirective:
        processErrorDirective(parseCtx);
        break;

    case PragmaDirective:
        processPragmaDirective(parseCtx);
        break;

    default:
        // Ignore directive. It may be of semantic importance to the source in another way.
    }
}

private void processInclude(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    if (parseCtx.inclusionDepth >= buildCtx.inclusionLimit) {
        throw new PreprocessException(parseCtx, "Inclusions has exceeded the limit of " ~
                buildCtx.inclusionLimit.to!string ~ ". Adjust BuildContext.inclusionLimit to increase.");
    }

    parseCtx.codePos -= 1;
    parseCtx.skipWhiteSpaceTillEol();
    char startChr = parseCtx.peek;
    bool absoluteInclusion;
    if (startChr == '"') {
        absoluteInclusion = false;
    } else if (startChr == '<') {
        absoluteInclusion = true;
    } else {
        throw new ParseException(parseCtx, "Failed to parse include directive: Expected \" or <.");
    }

    parseCtx.codePos += 1;
    const string includeName = parseCtx.collect(['"', '>']);
    parseCtx.replaceEnd = parseCtx.codePos;

    auto includeSource = includeName in buildCtx.sources;
    if (includeSource is null && !absoluteInclusion) {
        string currentDir = parseCtx.name.dirName;
        includeSource = currentDir ~ "/" ~ includeName in buildCtx.sources;
    }

    if (includeSource is null) {
        throw new PreprocessException(parseCtx, parseCtx.replaceStart, "Failed to include '" ~ includeName ~ "': It does not exist.");
    }

    if (parseCtx.guardedInclusions.canFind(includeName)) {
        parseCtx.clearStartToEnd();
        return;
    }

    string processedIncludeSource;
    string[] guardedInclusions = parseCtx.guardedInclusions;
    processFile(
        includeName,
        *includeSource,
        buildCtx,
        parseCtx.macros,
        guardedInclusions,
        processedIncludeSource,
        parseCtx.inclusionDepth + 1
    );

    parseCtx.macros[FileMacro] = parseCtx.name;
    parseCtx.guardedInclusions = guardedInclusions;
    parseCtx.replaceStartToEnd(processedIncludeSource);
}

private void processConditionalDirective(ref ParseContext parseCtx, const string directiveName) {
    bool negate = directiveName == IfNDefDirective;
    bool onlyCheckExistence = directiveName != IfDirective;
    processConditionalDirective(parseCtx, negate, onlyCheckExistence);
}

private void processConditionalDirective(ref ParseContext parseCtx, const bool negate, const bool onlyCheckExistence) {
    auto startOfConditionalBlock = parseCtx.replaceStart;
    parseCtx.codePos -= 1;
    parseCtx.skipWhiteSpaceTillEol();

    enum ConditionalBlockStartDirective = "startconditional";
    auto conditionalDirective = ConditionalBlockStartDirective;
    bool acceptedBody = false;
    bool processedElse = false;
    while (conditionalDirective != EndIfDirective) {
        if (conditionalDirective == ConditionalBlockStartDirective || conditionalDirective == ElIfDirective) {
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
        conditionalDirective = parseCtx.collect();
    }

    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();

    parseCtx.codePos = startOfConditionalBlock;
}

private void processDefineDirective(ref ParseContext parseCtx) {
    auto macroName = parseCtx.collect();
    if (macroName.length == 0) {
        throw new ParseException(parseCtx, "#define directive is missing name of macro.");
    }

    assertNotBuiltinMacro(parseCtx, macroName);

    string macroValue = null;
    auto isEndOfDefinition = endOfLineDelims.canFind(parseCtx.peekLast);
    if (!isEndOfDefinition) {
        macroValue = parseCtx.collect(endOfLineDelims).strip;
        if (macroValue[0] == '"' && macroValue[$ - 1] == '"') {
            macroValue = macroValue[1 .. $ - 1];
        }
    }

    parseCtx.macros[macroName] = macroValue;
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
}

private void processUndefDirective(ref ParseContext parseCtx) {
    auto macroName = parseCtx.collect();
    if (macroName.length == 0) {
        throw new ParseException(parseCtx, "#undef directive is missing name of macro.");
    }

    assertNotBuiltinMacro(parseCtx, macroName);

    parseCtx.macros.remove(macroName);
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
}

private void processErrorDirective(ref ParseContext parseCtx) {
    parseCtx.seekNext('"');
    auto errorMessage = parseCtx.collect(endOfLineDelims ~ '"');
    throw new PreprocessException(parseCtx, errorMessage);
}

private void processPragmaDirective(ref ParseContext parseCtx) {
    auto extensionName = parseCtx.collect();
    if (extensionName != PragmaOnceExtension) {
        throw new PreprocessException(parseCtx, "Pragma extension '" ~ extensionName ~ "' is unsupported.");
    }

    parseCtx.guardedInclusions ~= parseCtx.name;
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
}

private void processUnexpectedConditional(const ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    if (!buildCtx.ignoreUnmatchedConditionalDirectives) {
        throw new ParseException(parseCtx, "#endif directive found without accompanying starting conditional (#if/#ifdef)");
    }
}

private bool evaluateCondition(ref ParseContext parseCtx, const bool negate, const bool onlyCheckExistence) {
    auto expression = parseCtx.collect();
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
    auto macroName = parseCtx.collectTillString("__");
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

private void assertNotBuiltinMacro(ref ParseContext parseCtx, string macroName) {
    if (builtInMacros.canFind(macroName)) {
        throw new PreprocessException(parseCtx, "Cannot use macro name '" ~ macroName ~ "', it is a built-in macro.");
    }
}
