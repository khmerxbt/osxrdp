#include <cassert>
#include <vector>
#include <cstdio>
#include <cstdint>
#define private public
#include "../osxup/Paint/PaintRFX.h"
#undef private
int main(){PaintRFX p;uint32_t rng=1931;for(int w=1;w<=64;w++)for(int h=1;h<=64;h++){int stride=w*3+19;std::vector<unsigned char>src(stride*h+32),got(16384+64,0xa5),want(got);for(auto&v:src){rng=rng*1664525u+1013904223u;v=rng>>24;}for(int y=0;y<h;y++)for(int x=0;x<w;x++){want[32+y*64+x]=src[y*stride+x*3+1];want[32+4096+y*64+x]=src[y*stride+x*3+2];want[32+8192+y*64+x]=src[y*stride+x*3];}p.CopyRFXTile(src.data(),stride,got.data()+32,w,h);assert(got==want);}puts("PASS: production RemoteFX tile packing is byte-identical for all 4096 edge dimensions, padded source strides and destination guards");}
