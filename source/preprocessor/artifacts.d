/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module preprocessor.artifacts;

import preprocessor.parsing : ParseContext, calculateLineColumn;

import std.conv : to;

alias SourceMap = string[string];
alias MacroMap = string[string];

enum FileMacro = "FILE";
enum LineMacro = "LINE";
enum DateMacro = "DATE";
enum TimeMacro = "TIME";
enum TimestampMacro = "TIMESTAMP";

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
    MacroMap macros;

    /**
     * The maximum amount of inclusions allowed. This is to prevent 
     * an endless inclusion cycle.
     */
    uint inclusionLimit = 4000;

    /** 
     * Whether the parser should ignore #elseif, #else and #endif
     * directives that didn't come after a #if directive.
     * If true they will be kept in the result.
     */
    bool ignoreUnmatchedConditionalDirectives = false;
}

/** 
 * Result with modified source files.
 */
struct ProcessingResult {
    /// The processed (main) sources.
    SourceMap sources;

    /**
     * Textual date of when the processing started
     * e.g: Feb 16 2023
     */
    string date;

    /**
     * Textual time of when the processing started
     * e.g: 22:31:01
     */
    string time;

    /**
     * Textual timestamp of when the processing started
     * e.g: Thu Feb 16 22:38:10 2023
     */
    string timestamp;
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
    this(in ref ParseContext parseCtx, string msg, string file = __FILE__, size_t line = __LINE__) {
        this(parseCtx, parseCtx.codePos, msg, file, line);
    }

    this(in ref ParseContext parseCtx, ulong codePos, string msg, string file = __FILE__, size_t line = __LINE__) {
        ulong srcLine;
        ulong srcColumn;
        calculateLineColumn(parseCtx, codePos, srcLine, srcColumn);
        auto parseErrorMsg = "Error processing " ~ parseCtx.name ~ "(" ~ srcLine.to!string ~ "," ~ srcColumn
            .to!string ~ "): " ~ msg;
        super(parseErrorMsg, file, line);
    }
}
