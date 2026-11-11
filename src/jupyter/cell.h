#ifndef HAO_JUPYTER_CELL_H
#define HAO_JUPYTER_CELL_H
#include <stddef.h>
size_t hao_jupyter_rewrite_cell(const unsigned char *source, size_t length,
                                unsigned char *output, size_t capacity);
#endif
