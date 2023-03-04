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

// Note: the C code may not compile, I can't be bothered with writing proper C!

// See "examplesource/c" for the sources of these C files.

void main() {
    auto loggingh = import("logging.h");
    auto networkh = import("network.h");
    auto mainc = import("main.c");

    BuildContext buildCtx;

    // When mainSources is specified, only these files will be pre-processed.
    buildCtx.mainSources = ["main.c": mainc];

    // When mainSources is specified, the following files will only be available to includes.
    // They will not be part of the ProcessingResult.
    buildCtx.sources = [
        "logging.h": loggingh,
        "network.h": networkh,
        "stdio.h": "//stdio.h: stdlib not available."
    ];

    buildCtx.macros = [
        "ENABLE_NETWORKING": "true"
    ];

    // Finally call the preprocessor
    ProcessingResult result = preprocess(buildCtx);

    // Now for the results:
    writeln(result.sources["main.c"]);
}
