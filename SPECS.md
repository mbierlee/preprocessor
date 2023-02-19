# Pre-Processor Language Specifications

The pre-processor language is modeled after C's standard pre-processor language. However, some differences exist and not everything is supported.

## Convention

Specification examples show how to use the pre-processor. For example, a directive definition is written as such:

    #directive <mandatory> [optional]

The `#directive` here is a literal. Anything between `<` and `>` is mandatory and anything between `[` and `]` is optional.

Code examples follow with a filename and source code. There is no such thing as mandatory or optional brackets in these examples. These brackets are to be taken literal. Example:

_main.c_

```c
#include <stdio.h>

int main() {
    printf("Hello pre-processor.");
}
```

`<stdio.h>` is part of the `#include` directive. It does _not_ mean mandatory.

Because the language is similar to C, C examples will be used. These examples may not neccesarily compile correctly with a C compiler.

## Directives

Directives control the pre-processor; they tell it what to do and how to modify the given source code. Directive tokens always start with a `#`.

### `#include`

    #include <source name>

Includes another source (file) into the current source.

_main.c_

```c
#include "main.h"

int main() {
    printHello();
}
```

_main.h_

```c
void printHello() {
    printf("Hello pre-processor.");
}
```

All contents of `main.h` will be included into `main.c`. Since the pre-processor is language agnostic, the comment will also be included as-is.

Includes can also be included using `<` and `>` (diamonds):

_main.c_

```c
#include <main.h>
```

Includes with quotes are directory-aware and will first look for an include that is a sibbling of the current file in the directory tree, whereas includes with diamonds are absolute.

### `#if`

    #if <expression>

Evaluates the given expression. The expression is _true_ when it results in anything other than `0`, `false` or `null` (in D, not the string null).

_main.c_

```c
#if PRINT_DEBUG
    printf("Debug!");
#elif PRINT_WARNING
    printf("Warning!");
#else
    printf("Info?");
#endif
```

Currently only _object-like macros_ are supported as expressions. These need to be pre-defined either in sources or when calling the pre-processor.

_Note: conditional directives inside of conditional directives are not supported._

### `#ifdef`/`#ifndef`

    #ifdef <macro>
    #ifndef <macro>

Check whether a macro is defined or not.

_main.c_

```c
#ifdef WINDOWS
// Windows-specific code goes here.
#endif

#ifndef MAC_OS
// Code for any platform but MacOS.
#endif
```

_Note: There are no pre-defined platform macros in the pre-processor. These need to be manually defined in your D code._

_Note 2: conditional directives inside of conditional directives are not supported._

### `#define`/`#undef`

    #define <macro name> [value]
    #undef <macro name>

Define or undefine a macro.

_main.c_

```c
#define DO_THING
#ifdef DO_THING
// This code will be included, since the macro is defined.
#endif

#undef DO_THING
#ifndef
// This code will be included, since the macro is not longer defined.
#endif

#define the_truth some text string here
// Macro the_truth contains the whole string "some text string here".

#if the_truth
// Code will be included because any value that is not '0', 'false' or null evaluates to true.
#endif

#define lies 0
#if lies
// This code will not be included, lies is falsy.
#endif

#define valueless
#if valueless
// This code will not be included, since the value is technically null.
#endif
```

### `#error`

    #error <error message>

When processed, the pre-processing will fail and a `PreprocessException` is thrown in the calling D code.

_main.c_

```c
#error "Pre-processing will fail with this message"
```

When used in conditionals, the error is not thrown if the expression evaluates to false.

_winlib.h_

```c
#ifndef WINDOWS
#error "Only Windows is supported."
#endif
```

### `#pragma`

    #pragma <extension parameters>

Pragma directives are used to call custom pre-processor methods.
At the moment only one pragma extension is supported: `once`.

#### `#pragma once`

To prevent double-inclusion, traditionally C code would contain a custom made _inclusion guard_:

_lib.h_

```c
#ifndef LIB_H
#define LIB_H
// Contents that are only to be included once.
#endif
```

When `lib.h` ends up being included multiple times in the same source file, it will be empty because of the inclusion guard. This however is not fool-proof and adds a bit of boilerplate.

These are particularly problematic because:

- It is not possible to nest conditional directives. Using an inclusion guard eliminates the possibility of using other conditional directives inside;
- Included sources are processed before being added to the source that includes them. When deeply-included sources are processed, the inclusion guards will be gone, allowing for double-inclusion elsewhere.

The `#pragma once` directive will solve this and is the preferred method:

_lib.h_

```c
#pragma once
// Contents that are only to be included once.
```

The pragma can be put anywhere in the source and even be conditionally used. It is customary to use it at the top of a source.

## Macro Expansion

Defined macros can be used anywhere in a source file, as long as they are pre- and post-fixed with double underscores.

_main.c_

```c
#define HELLO "Hello World!"

int main() {
    printf(__HELLO__);
}
```

When used in conditional directives, they can be used either with or without underscores:

_main.c_

```c
#define DEBUG_MODE true

#ifdef DEBUG_MODE
// Contents will be in source
#endif

#ifdef __DEBUG_MODE__
// Contents will be in source
#endif

#if DEBUG_MODE
// Contents will be in source

#endif

#if __DEBUG_MODE__
// Contents will be in source
#endif
```
