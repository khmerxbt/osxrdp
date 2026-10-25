#include "osxup/Channel/RdpAudioOutput.h"
#include <cassert>
#include <cstdio>
#include <random>
static unsigned u16(const std::vector<uint8_t>& p,int i) { return p[i]|unsigned(p[i+1])<<8; }
int main() {
 RdpAudioOutput audio;
 std::vector<std::vector<uint8_t>> sent;
 auto send=[](void* context,const uint8_t* p,size_t n) { auto& out=*(std::vector<std::vector<uint8_t>>*)context; out.emplace_back(p,p+n); return 0; };
 int16_t pcm[2048] = {};
 assert(!audio.Pcm(pcm,sizeof(pcm),1234));
 audio.Start(send,&sent);
 assert(sent.size()==1 && sent[0].size()==42 && sent[0][0]==7 && u16(sent[0],2)==38);
 auto formats = sent[0]; formats[4] = 1;
 // Channel fragment reconstruction must wait for the LAST flag.
 audio.Receive(formats.data(),10,1,formats.size()); assert(sent.size()==1);
 audio.Receive(formats.data()+10,formats.size()-10,2,formats.size());
 assert(sent.size()==2 && sent.back()[0]==6 && !audio.Ready());
 auto training=sent.back();
 std::vector<uint8_t> confirm{6,0,4,0,training[4],training[5],training[6],training[7]};
 audio.Receive(confirm.data(),confirm.size(),3,confirm.size()); assert(audio.Ready());
 for (int i=0;i<8;++i) assert(audio.Pcm(pcm,sizeof(pcm),1234+i));
 assert(!audio.Pcm(pcm,sizeof(pcm),1242));
 auto wave=sent.back();
 assert(wave[0]==13 && wave.size()==16+sizeof(pcm) && u16(wave,2)==12+sizeof(pcm));
 assert(wave[8]==7 && wave[12]==(1241&255));
 std::vector<uint8_t> ack{5,0,4,0,0,0,7,0};
 audio.Receive(ack.data(),ack.size(),3,ack.size());
 assert(audio.Pcm(pcm,sizeof(pcm),1243));
 audio.Receive(ack.data(),ack.size(),3,ack.size());
 assert(!audio.Pcm(pcm,sizeof(pcm),1244)); // Duplicate ACK cannot release a slot twice.
 assert(!audio.Pcm(pcm,3,100) && !audio.Pcm(pcm,8192,100));
 for (int i=0;i<256;++i) { ack[6]=(uint8_t)i; audio.Receive(ack.data(),ack.size(),3,ack.size()); }
 for (int i=0;i<520;++i) {
  assert(audio.Pcm(pcm,4,2000+i));
  ack[6]=sent.back()[8]; audio.Receive(ack.data(),ack.size(),3,ack.size());
 }
 // Old clients and malformed/unadvertised formats cannot enable audio.
 auto invalid=formats; invalid[21]=7;
 audio.Receive(invalid.data(),invalid.size(),3,invalid.size()); assert(!audio.Ready());
 invalid=formats; invalid[18]=255; invalid[19]=255;
 audio.Receive(invalid.data(),invalid.size(),3,invalid.size()); assert(!audio.Ready());
 invalid=formats; invalid[28]=0;
 audio.Receive(invalid.data(),invalid.size(),3,invalid.size()); assert(!audio.Ready());
 audio.Reset(); assert(!audio.Ready() && !audio.Pcm(pcm,4,100));
 // Bound and fuzz the network-facing fragment/PDU parser under ASan/UBSan.
 std::mt19937 rng(2345);
 for (int i=0;i<50000;++i) {
  std::vector<uint8_t> input(rng()%300+1);
  for (auto& b:input) b=(uint8_t)rng();
  audio.Receive(input.data(),input.size(),rng()%4,rng()%70000);
 }
 puts("PASS: PCM formats/training, channel fragments, WAVE2 bytes, bounded flow control, ACK replay/wrap, invalid clients, parser fuzz");
}
