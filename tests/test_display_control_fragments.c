#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include "../scripts/display_control_fragments.h"
int main(void){struct xrdp_display_control_fragments s={0};char layout[656];for(int i=0;i<656;i++)layout[i]=(char)i;const char*out=NULL;int n=0;
 assert(xrdp_display_control_feed(&s,layout,56,0,0,&out,&n)==1&&n==56&&!memcmp(out,layout,56));
 assert(xrdp_display_control_feed(&s,layout,56,56,1,&out,&n)==1&&n==56&&!memcmp(out,layout,56));
 for(int split=1;split<656;split++){assert(xrdp_display_control_feed(&s,layout,split,656,1,&out,&n)==0);assert(!out&&!n);assert(xrdp_display_control_feed(&s,layout+split,656-split,0,0,&out,&n)==1&&n==656&&!memcmp(out,layout,656));}
 assert(xrdp_display_control_feed(&s,layout,2,56,1,&out,&n)==0);for(int i=2;i<56;i++)assert(xrdp_display_control_feed(&s,layout+i,1,0,0,&out,&n)==(i==55?1:0));assert(n==56&&!memcmp(out,layout,56));
 assert(xrdp_display_control_feed(&s,layout,1,657,1,&out,&n)==-1);
 assert(xrdp_display_control_feed(&s,layout,10,9,1,&out,&n)==-1);
 assert(xrdp_display_control_feed(&s,layout,5,56,1,&out,&n)==0);assert(xrdp_display_control_feed(&s,layout,52,0,0,&out,&n)==-1);
 assert(xrdp_display_control_feed(&s,layout,5,56,1,&out,&n)==0);assert(xrdp_display_control_feed(&s,layout,56,56,1,&out,&n)==-1);assert(!s.expected&&!s.used);
 uint32_t r=347;for(int i=0;i<100000;i++){r=r*1664525+1013904223;int bytes=(r%700)-20;r=r*1664525+1013904223;int total=(r%700)-20;xrdp_display_control_feed(&s,layout,bytes,total,r&1,&out,&n);assert(s.used>=0&&s.used<=s.expected&&s.expected<=656);}
 puts("PASS: plain/data-first monitor layouts, all 655 split points, byte fragments, oversized/interleaved/truncated input and 100000 malformed sequences under ASan/UBSan");}
