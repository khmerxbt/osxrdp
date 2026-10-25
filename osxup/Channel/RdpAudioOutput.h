#ifndef OSXRDP_AUDIO_OUTPUT_H
#define OSXRDP_AUDIO_OUTPUT_H

#include <time.h>
#include <cstdint>

#include <vector>

// MS-RDPEA: bounded TCP-only PCM/WAVE2 output. No microphone/UDP channel.
class RdpAudioOutput {
public:
    using Send = int (*)(void*, const uint8_t*, size_t);
    void Reset() { _send = nullptr; _context = nullptr; _rx.clear(); _expected = 0; _format = -1;
        _trained = false; for (bool& value : _pending) value = false; _inFlight = 0; _block = 0; }
    void Start(Send send, void* context = nullptr) {
        Reset(); _send = send; _context = context;
        std::vector<uint8_t> body;
        u32(body,0); u32(body,0xffffffff); u32(body,0x10000);
        u16(body,0); u16(body,1); body.push_back(0); u16(body,8); body.push_back(0);
        u16(body,1); u16(body,2); u32(body,48000); u32(body,192000);
        u16(body,4); u16(body,16); u16(body,0);
        sendPdu(7,body);
    }
    bool Ready() const { return _format >= 0 && _trained; }
    void Receive(const uint8_t* p, size_t n, int flags, size_t total) {
        if (!p || !n || !total || total > 65536 || n > total) { clearRx(); return; }
        if (flags & 1) { clearRx(); _expected = total; }
        if (!_expected || total != _expected || _rx.size()+n > _expected) { clearRx(); return; }
        _rx.insert(_rx.end(),p,p+n);
        if (!(flags & 2)) return;
        if (_rx.size() != _expected) { clearRx(); return; }
        // More than one complete RDPSND PDU may share a channel message.
        size_t offset = 0;
        while (_rx.size()-offset >= 4) {
            size_t size = r16(_rx.data()+offset+2);
            if (size > _rx.size()-offset-4) break;
            handle(_rx[offset],_rx.data()+offset+4,size);
            offset += size+4;
        }
        clearRx();
    }
    bool Pcm(const void* samples, size_t bytes, uint32_t timestamp) {
        if (!Ready() || !samples || !bytes || bytes > 4096 || bytes%4 || _inFlight >= 8) return false;
        std::vector<uint8_t> body; body.reserve(12+bytes);
        u16(body,static_cast<uint16_t>(now())); u16(body,static_cast<uint16_t>(_format));
        uint8_t block = _block++;
        body.push_back(block); body.insert(body.end(),3,0); u32(body,timestamp);
        const auto* pcm = static_cast<const uint8_t*>(samples);
        body.insert(body.end(),pcm,pcm+bytes);
        if (!sendPdu(13,body)) return false;
        _pending[block] = true; ++_inFlight;
        return true;
    }
private:
    Send _send = nullptr;
    void* _context = nullptr;
    std::vector<uint8_t> _rx;
    size_t _expected = 0;
    int _format = -1, _inFlight = 0;
    bool _trained = false;
    uint8_t _block = 0;
    uint16_t _trainingTime = 0;
    bool _pending[256] = {};
    static uint32_t now() {
        struct timespec t;
        clock_gettime(CLOCK_MONOTONIC, &t);
        return static_cast<uint32_t>(uint64_t(t.tv_sec)*1000 + t.tv_nsec/1000000);
    }
    static uint16_t r16(const uint8_t* p) { return p[0] | uint16_t(p[1])<<8; }
    static uint32_t r32(const uint8_t* p) { return r16(p) | uint32_t(r16(p+2))<<16; }
    static void u16(std::vector<uint8_t>& b, uint16_t v) { b.push_back(v); b.push_back(v>>8); }
    static void u32(std::vector<uint8_t>& b, uint32_t v) { u16(b,v); u16(b,v>>16); }
    void clearRx() { _rx.clear(); _expected = 0; }
    bool sendPdu(uint8_t type, const std::vector<uint8_t>& body) {
        if (!_send || body.size()>65535) return false;
        std::vector<uint8_t> p{type,0}; u16(p,static_cast<uint16_t>(body.size()));
        p.insert(p.end(),body.begin(),body.end());
        return _send(_context,p.data(),p.size()) == 0;
    }
    void handle(uint8_t type, const uint8_t* p, size_t n) {
        if (type == 7) {
            _format = -1; _trained = false; for (bool& value : _pending) value = false; _inFlight = 0;
            if (n<20 || !(r32(p)&1) || r16(p+17)<8) return;
            unsigned count = r16(p+14);
            if (count>128) return;
            size_t pos = 20;
            int selected = -1;
            for (unsigned i=0;i<count;++i) {
                if (n-pos<18) return;
                size_t extra = r16(p+pos+16);
                if (extra>n-pos-18) return;
                if (r16(p+pos)==1 && r16(p+pos+2)==2 && r32(p+pos+4)==48000
                    && r32(p+pos+8)==192000 && r16(p+pos+12)==4
                    && r16(p+pos+14)==16 && extra==0) selected = static_cast<int>(i);
                pos += 18+extra;
            }
            if (pos!=n || selected<0) return;
            _format = selected;
            _trainingTime = static_cast<uint16_t>(now());
            std::vector<uint8_t> b; u16(b,_trainingTime); u16(b,1032); b.insert(b.end(),1024,0);
            sendPdu(6,b);
        } else if (type == 6 && n==4 && _format>=0) {
            _trained = r16(p)==_trainingTime && r16(p+2)==1032;
        } else if (type == 5 && n==4) {
            uint8_t block = p[2];
            if (_pending[block]) { _pending[block] = false; --_inFlight; }
        }
    }
};
#endif
