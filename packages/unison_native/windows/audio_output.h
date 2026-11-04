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
std::vector<std::string> devices();
void device(const std::string& name);
void volume(double value);
double volume();
}
