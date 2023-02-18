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

public import preprocessor.artifacts;

import preprocessor.processing : processFile;

import std.datetime.systime : SysTime, Clock;
import std.conv : to;
import std.string : capitalize, rightJustify;

/** 
 * Preprocess the sources contained in the given build context.
 * Params:
 *   buildCtx = Context used in the pre-processing run.
 * Returns: A procesing result containing all processed (main) sources.
 */
ProcessingResult preprocess(const ref BuildContext buildCtx) {
    ProcessingResult result;
    result.date = createDateString();
    result.time = createTimeString();
    result.timestamp = createTimestampString();

    const MacroMap builtInMacros = [
        DateMacro: result.date,
        TimeMacro: result.time,
        TimestampMacro: result.timestamp
    ];

    const(SourceMap) sources = buildCtx.mainSources.length > 0 ? buildCtx.mainSources
        : buildCtx.sources;

    MacroMap macros = createInitialMacroMap(builtInMacros, buildCtx);
    foreach (string name, string source; sources) {
        string resultSource;
        processFile(name, source, buildCtx, macros, resultSource);
        result.sources[name] = resultSource;
    }

    return result;
}

private MacroMap createInitialMacroMap(const MacroMap builtInMacros, const ref BuildContext buildCtx) {
    MacroMap macros = cast(MacroMap) buildCtx.macros.dup;
    foreach (string macroName, string macroValue; builtInMacros) {
        macros[macroName] = macroValue;
    }

    return macros;
}

private string createDateString() {
    SysTime currentTime = Clock.currTime();
    auto month = currentTime.month.to!string.capitalize;
    auto day = currentTime.day.to!string.rightJustify(2, '0');
    auto year = currentTime.year.to!string;
    return month ~ " " ~ day ~ " " ~ year;
}

private string createTimeString() {
    SysTime currentTime = Clock.currTime();
    auto hour = currentTime.hour.to!string.rightJustify(2, '0');
    auto minute = currentTime.minute.to!string.rightJustify(2, '0');
    auto second = currentTime.second.to!string.rightJustify(2, '0');
    return hour ~ ":" ~ minute ~ ":" ~ second;
}

private string createTimestampString() {
    SysTime currentTime = Clock.currTime();
    auto dayOfWeek = currentTime.dayOfWeek.to!string.capitalize;
    auto month = currentTime.month.to!string.capitalize;
    auto day = currentTime.day.to!string.rightJustify(2, '0');
    auto time = createTimeString();
    auto year = currentTime.year.to!string;
    return dayOfWeek ~ " " ~ month ~ " " ~ day ~ " " ~ time ~ " " ~ year;
}

version (unittest) {
    import preprocessor.debugging;

    import std.exception : assertThrown;
    import std.string : strip;
    import std.array : replace;
    import std.conv : to;

    string stripAllWhiteSpace(string input) {
        return input.replace(' ', "").replace('\n', "");
    }

    void assertThrownMsg(ExceptionT : Throwable = Exception, ExpressionT)(
        string expectedMessage, lazy ExpressionT expression) {
        try {
            expression;
            assert(false, "No exception was thrown. Expected: " ~ typeid(ExceptionT).to!string);
        } catch (ExceptionT e) {
            assert(e.message == expectedMessage, "Exception message was different. Expected: \"" ~ expectedMessage ~
                    "\", actual: \"" ~ e.message ~ "\"");
        } catch (Exception e) {
            //dfmt off
            assert(false, "Different type of exception was thrown. Expected: " ~
                    typeid(ExceptionT).to!string ~ ", actual: " ~ typeid(typeof(e)).to!string);
            //dfmt on
        }
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

        assertThrownMsg!ParseException(
            "Error processing main.txt(2,1): Parse error: Failed to parse include directive: Expected \" or <.",
            preprocess(context)
        );
    }

    @("Fail to include when filename does not start with quote or <")
    unittest {
        auto main = "#include 'coolfile.c'";
        auto context = BuildContext([
                "main.txt": main
            ]);

        assertThrownMsg!ParseException(
            "Error processing main.txt(0,9): Parse error: Failed to parse include directive: Expected \" or <.",
            preprocess(context)
        );
    }

    @("Fail to include when included source is not in build context")
    unittest {
        auto main = "#include <notfound.404>";
        auto context = BuildContext([
                "main.txt": main
            ]);

        assertThrownMsg!PreprocessException(
            "Error processing main.txt(0,0): Failed to include 'notfound.404': It does not exist.",
            preprocess(context)
        );
    }

    @("Prevent endless inclusion cycle")
    unittest {
        auto main = "#include \"main.txt\"";
        auto context = BuildContext([
                "main.txt": main
            ]);
        context.inclusionLimit = 5;

        assertThrownMsg!PreprocessException(
            "Error processing main.txt(0,9): Inclusions has exceeded the limit of 5. Adjust BuildContext.inclusionLimit to increase.",
            preprocess(context)
        );
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

        assertThrownMsg!ParseException(
            "Error processing main(0,6): Parse error: #endif directive found without accompanying starting conditional (#if/#ifdef)",
            preprocess(context)
        );
    }

    @("Fail if a rogue #else is found")
    unittest {
        auto main = "#else";
        auto context = BuildContext(["main": main]);

        assertThrownMsg!ParseException(
            "Error processing main(0,5): Parse error: #endif directive found without accompanying starting conditional (#if/#ifdef)",
            preprocess(context)
        );
    }

    @("Fail if a rogue #elsif is found")
    unittest {
        auto main = "#elsif";
        auto context = BuildContext(["main": main]);

        assertThrownMsg!ParseException(
            "Error processing main(0,6): Parse error: #endif directive found without accompanying starting conditional (#if/#ifdef)",
            preprocess(context)
        );
    }

    @("Not fail if a rogue #endif is found and ignored")
    unittest {
        auto main = "#endif";
        auto context = BuildContext(["main": main]);
        context.ignoreUnmatchedConditionalDirectives = true;

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "#endif");
    }

    @("Not fail if a rogue #else is found and ignored")
    unittest {
        auto main = "#else";
        auto context = BuildContext(["main": main]);
        context.ignoreUnmatchedConditionalDirectives = true;

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "#else");
    }

    @("Not fail if a rogue #elsif is found and ignored")
    unittest {
        auto main = "#elsif";
        auto context = BuildContext(["main": main]);
        context.ignoreUnmatchedConditionalDirectives = true;

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "#elsif");
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
        assertThrownMsg!ParseException(
            "Error processing main(3,1): Parse error: #else directive defined multiple times. Only one #else block is allowed.",
            preprocess(context)
        );
    }

    @("Fail when end of file is reached before conditional terminator")
    unittest {
        auto main = "
            #ifdef I_AM_GROOT
            Groot!
        ";

        auto context = BuildContext(["main": main]);
        assertThrownMsg!ParseException(
            "Error processing main(3,9): Parse error: Unexpected end of file while processing directive.",
            preprocess(context)
        );
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

        assertThrownMsg!ParseException(
            "Error processing main(2,1): Parse error: #endif directive found without accompanying starting conditional (#if/#ifdef)",
            preprocess(context)
        );
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
        assertThrownMsg!ParseException(
            "Error processing main.c(1,21): Parse error: Cannot expand macro __MOTOR__, it is undefined.",
            preprocess(context)
        );
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

    @("Built-in macro __DATE__ is defined")
    unittest {
        auto main = "
            #ifdef __DATE__
                __DATE__
            #endif
        ";

        auto context = BuildContext(["main.c": main]);
        auto result = preprocess(context);
        assert(result.sources["main.c"].strip == result.date);
    }

    @("Built-in macro __TIME__ is defined")
    unittest {
        auto main = "
            #ifdef __TIME__
                __TIME__
            #endif
        ";

        auto context = BuildContext(["main.c": main]);
        auto result = preprocess(context);
        assert(result.sources["main.c"].strip == result.time);
    }

    @("Built-in macro __TIMESTAMP__ is defined")
    unittest {
        auto main = "
            #ifdef __TIMESTAMP__
                __TIMESTAMP__
            #endif
        ";

        auto context = BuildContext(["main.c": main]);
        auto result = preprocess(context);
        assert(result.sources["main.c"].strip == result.timestamp);
    }

    @("Ignore detached second underscore as part of possible macro")
    unittest {
        auto main = "IM_AM_NOT_A_MACRO";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"] == "IM_AM_NOT_A_MACRO");
    }

    @("Define an empty macro")
    unittest {
        auto main = "
            #define RTX_ON
            #ifdef RTX_ON
                It's on!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"].strip == "It's on!");
    }

    @("Define macro with value")
    unittest {
        auto main = "
            #define RTX_ON true
            #if RTX_ON
                It's awwwn!
            #endif
        ";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"].strip == "It's awwwn!");
    }

    @("Fail when defining a macro but the name is missing")
    unittest {
        auto main = "
            #define
            Fail!
        ";

        auto context = BuildContext(["main": main]);
        assertThrownMsg!ParseException(
            "Error processing main(2,2): Parse error: #define directive is missing name of macro.",
            preprocess(context)
        );
    }

    @("Undefine macro")
    unittest {
        auto main = "
            #define RTX_ON
            #undef RTX_ON
            #ifdef RTX_ON
                It's on!
            #else
                It's all the way off.
            #endif
        ";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"].strip == "It's all the way off.");
    }

    @("Undefine pre-defined macro")
    unittest {
        auto main = "
            #undef RTX_ON
            #ifndef RTX_ON
                It's all the way off.
            #endif
        ";

        auto context = BuildContext(["main": main]);
        context.macros = ["RTX_ON": "true"];

        auto result = preprocess(context).sources;
        assert(result["main"].strip == "It's all the way off.");
    }

    @("Fail when undefining a macro but the name is missing")
    unittest {
        auto main = "
            #undef
            Fail!
        ";

        auto context = BuildContext(["main": main]);
        assertThrownMsg!ParseException(
            "Error processing main(2,2): Parse error: #undef directive is missing name of macro.",
            preprocess(context)
        );
    }
}

// Error tests
version (unittest) {
    @("Error directive is thrown")
    unittest {
        auto main = "
            #error This unit test should fail?
        ";

        auto context = BuildContext(["main": main]);
        assertThrownMsg!PreprocessException(
            "Error processing main(2,1): This unit test should fail?",
            preprocess(context)
        );
    }

    @("Error directive is not thrown when skipped in conditional")
    unittest {
        auto main = "
            #ifdef __WINDOWS__
                #error We don't support windows here!
            #endif

            Zen
        ";

        auto context = BuildContext(["main": main]);
        auto result = preprocess(context).sources;
        assert(result["main"].strip == "Zen");
    }
}

// Advanced tests
version (unittest) {
    @("Inclusion guards")
    unittest {
        auto lib = "
            #ifndef CAKE_PHP
            #define CAKE_PHP
            Cake!
            #endif
        ";

        auto main = "
            #include <cake.php>
            #include <cake.php>
        ";

        BuildContext context;
        context.mainSources = ["main.php": main];
        context.sources = ["cake.php": lib];

        auto result = preprocess(context).sources;
        assert(result["main.php"].strip == "Cake!");
    }
}

//TODO: #pragma once
//TODO: conditionals in conditionals?
