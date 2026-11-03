#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace unison {

int64_t monotonicUs();

class Receiver {
public:
    Receiver();
    ~Receiver();
    bool start(const std::string& sourceIp = "");
    void stop();
    void setOffsetMs(float ms);
    // firstFrameUs 是本次输出第一帧实际发声的本机单调时刻。
    void render(float* stereo, int frames, int deviceRate, int64_t firstFrameUs,
                bool realTimestamp);
    std::string statsJson();

private:
    struct State;
    std::unique_ptr<State> state_;
};

}  // namespace unison
