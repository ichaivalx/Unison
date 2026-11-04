#pragma once
#include <cstdint>
#include <string>
#include <vector>
namespace unison_windows {
uint64_t receiverId();
bool start(const std::string& source);
void stop();
void offset(int64_t us);
std::string stats();
struct OutputDevice { std::string id, name; };
std::vector<OutputDevice> devices();
void device(const std::string& id);
void volume(double value);
double volume();
}
