#ifndef HAO_ZIG_BINDINGS_H
#define HAO_ZIG_BINDINGS_H
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#include <direct.h>
#define access _access
#define mkdir(path, mode) _mkdir(path)
#else
#include <unistd.h>
#endif
#include <quickjs.h>
#endif
