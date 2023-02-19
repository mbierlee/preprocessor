/**
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2023 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

import preprocessor;

import std.stdio;

//Note: the C code may not compile, I can't be bothered with writing proper C!

void main() {
    auto loggingh = import("logging.h");
    auto networkh = import("network.h");
    auto mainc = import("main.c");

    BuildContext buildCtx;

    // Add all files as sources to be pre-processed.
    buildCtx.sources = [
        "main.c": mainc,
        "logging.h": loggingh,
        "network.h": networkh,
        "stdio.h": "//stdio.h: stdlib not available."
    ];

    // Pre-define macros that are used in the sources.
    buildCtx.macros = [
        "ENABLE_NETWORKING": "true"
    ];

    // Finally call the preprocessor
    ProcessingResult result = preprocess(buildCtx);

    // Now do whatever you need to do with your sources. Pull them through a compiler if you dare!
    writeln(result.sources["main.c"]);
}
