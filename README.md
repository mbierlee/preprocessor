# Language-agnostic Preprocessor for D

Version 1.0.0  
Copyright 2023 Mike Bierlee  
Licensed under the terms of the MIT license - See [LICENSE.txt](LICENSE.txt)

[![DUB Package](https://img.shields.io/dub/v/preprocessor.svg)](https://code.dlang.org/packages/preprocessor)

A language-agnostic preprocessor library for D. It allows you to pre-process code or text in any language using C-like directives. This is not a CLI tool, only a library. The library does not deal with reading or writing files, that is up to the user. 

See the `examples/` directory for how to use it and [SPECS.md](SPECS.md) for more details on what is supported in the pre-processing language. Finally, if you want to see some detailed examples, see the unittests in [source/preprocessor/package.d](package.d).

## Projects Using The Pre-Processor

- [The Retrograde Game Engine](https://github.com/mbierlee/retrograde): General purpose game engine.
