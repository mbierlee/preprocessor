/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor.processing;

import preprocessor.artifacts : SourceCode, Name, BuildContext, PreprocessException, ParseException, FileMacro,
    LineMacro;
import preprocessor.parsing : ParseContext, parse, collect, DirectiveStart, MacroStartEnd, skipWhiteSpaceTillEol, peek,
    replaceStartToEnd, clearStartToEnd, endOfLineDelims, peekLast, seekNextDirective, calculateLineColumn;
import preprocessor.debugging;

import std.conv : to;
import std.path : dirName;
import std.algorithm : canFind;
import std.string : toLower, startsWith, endsWith;
import std.array : replaceInPlace;

private enum IncludeDirective = "include";
private enum IfDirective = "if";
private enum IfDefDirective = "ifdef";
private enum IfNDefDirective = "ifndef";
private enum ElsIfDirective = "elsif";
private enum ElseDirective = "else";
private enum EndIfDirective = "endif";
private enum DefineDirective = "define";
private enum UndefDirective = "undef";
private enum ErrorDirective = "error";

private static const string[] conditionalTerminators = [
    ElsIfDirective, ElseDirective, EndIfDirective
];

package SourceCode processFile(
    const Name name,
    const ref SourceCode source,
    const ref BuildContext buildCtx,
    ref string[string] builtInMacros
) {
    builtInMacros[FileMacro] = name;
    builtInMacros[LineMacro] = "0";

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
    case ElsIfDirective:
        processUnexpectedConditional(parseCtx, buildCtx);
        break;
    case ErrorDirective:
        processErrorDirective(parseCtx);
        break;
    default:
        // Ignore directive. It may be of semantic importance to the source in another way.
    }
}

private void processInclude(ref ParseContext parseCtx, const ref BuildContext buildCtx) {
    if (parseCtx.inclusions >= buildCtx.inclusionLimit) {
        throw new PreprocessException(parseCtx, "Inclusions has exceeded the limit of " ~
                buildCtx.inclusionLimit.to!string ~ ". Adjust BuildContext.inclusionLimit to increase.");
    }

    parseCtx.inclusions += 1;
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

    string macroValue = null;
    auto isEndOfDefinition = endOfLineDelims.canFind(parseCtx.peekLast);
    if (!isEndOfDefinition) {
        macroValue = parseCtx.collect(endOfLineDelims);
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

    parseCtx.macros.remove(macroName);
    parseCtx.replaceEnd = parseCtx.codePos;
    parseCtx.clearStartToEnd();
}

private void processErrorDirective(ref ParseContext parseCtx) {
    auto errorMessage = parseCtx.collect(endOfLineDelims);
    throw new PreprocessException(parseCtx, errorMessage);
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
    auto macroName = parseCtx.collect([MacroStartEnd]);
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
