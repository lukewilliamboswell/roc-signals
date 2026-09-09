/* Force a compiler-runtime division call whose result exceeds 64 bits. */
static volatile __int128 numerator = ((__int128)1 << 100) + 123;
static volatile __int128 denominator = 3;
int main(void) {
    __int128 quotient = numerator / denominator;
    return quotient == (((__int128)1 << 100) + 123) / 3 ? 0 : 62;
}
