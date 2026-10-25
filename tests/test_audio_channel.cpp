#include <vector>
#include <cassert>
#include <cstring>
#include <cstdio>
#include "osxup/osxup.h"
struct Fragment { std::vector<unsigned char> bytes; int total, flags; };
static std::vector<Fragment> output;
static int channelId(mod*, const char* name) { return strcmp(name,"rdpsnd")==0 ? 3 : 2; }
static int send(mod*, int channel, char* bytes, int size, int total, int flags) {
 assert(channel==3 && size>0 && size<=1600);
 output.push_back({std::vector<unsigned char>(bytes,bytes+size),total,flags}); return 0;
}
int main() {
 mod m{}; m.server_get_channel_id=channelId; m.server_send_to_channel=send;
 ChannelManager manager; assert(manager.Initialize(&m)); manager.SendAudioServerInit(); assert(!manager.IsAudioReady());
 assert(output.size()==1 && output[0].flags==3);
 auto formats=output[0].bytes; formats[4]=1;
 assert(manager.HandleAudioChannel(3,3,(char*)formats.data(),formats.size(),formats.size()));
 assert(output.back().bytes[0]==6 && output.back().bytes.size()==1032);
 auto training=output.back().bytes;
 unsigned char ackTraining[]={6,0,4,0,training[4],training[5],training[6],training[7]};
 manager.HandleAudioChannel(3,3,(char*)ackTraining,8,8);
 assert(manager.IsAudioReady());
 output.clear(); short pcm[2048]={}; manager.SendAudioPcm(pcm,sizeof(pcm),123456);
 assert(output.size()==3 && output[0].flags==1 && output[1].flags==0 && output[2].flags==2);
 size_t n=0; for (const auto& item:output) { assert(item.total==4112); n+=item.bytes.size(); }
 assert(n==4112 && output[0].bytes[0]==13);
 assert(!manager.HandleAudioChannel(9,3,(char*)ackTraining,8,8));
 manager.Release(); assert(!manager.IsAudioReady());
 puts("PASS: real XRDP channel integration, PCM negotiation/training, 1600-byte fragmentation, total length/FIRST/LAST flags");
}
