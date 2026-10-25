/* Compare the production transform with an unmodified scalar reference.
 * Compile the reference with -Drfx_encode_dwt_shift_rem=scalar_dwt. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int rfx_encode_dwt_shift_rem(const unsigned char *, short *, short *, const char *);
int scalar_dwt(const unsigned char *, short *, short *, const char *);

int main(void)
{
    unsigned char input[4096];
    short reference[4098], actual[4098], reference_scratch[4098], scratch[4098];
    uint32_t seed = 42;
    char quants[5];

    for (int test = 0; test < 10000; ++test)
    {
        for (int i = 0; i < 4096; ++i)
        {
            seed = seed * 1664525 + 1013904223;
            input[i] = test < 256 ? test : seed >> 24;
        }
        for (int i = 0; i < 5; ++i)
        {
            seed = seed * 1664525 + 1013904223;
            quants[i] = ((6 + seed % 10) << 4) | (6 + (seed >> 8) % 10);
        }
        memset(reference, 0xa5, sizeof(reference));
        memset(actual, 0xa5, sizeof(actual));
        memset(reference_scratch, 0x5a, sizeof(reference_scratch));
        memset(scratch, 0x5a, sizeof(scratch));
        scalar_dwt(input, reference + 1, reference_scratch + 1, quants);
        rfx_encode_dwt_shift_rem(input, actual + 1, scratch + 1, quants);
        if (memcmp(reference, actual, sizeof(actual)) ||
                memcmp(reference_scratch, scratch, sizeof(scratch)))
        {
            fprintf(stderr, "Transform mismatch at test %d\n", test);
            return 1;
        }
    }
    puts("PASS: 10000 tiles, quantization variants, output/scratch/guards identical");
    return 0;
}
