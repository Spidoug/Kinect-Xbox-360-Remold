#pragma once
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "remold/protocol.hpp"

namespace remold::devices {
struct Endpoint { std::string id; std::string label; std::string endpoint; };

inline std::vector<Endpoint> read_manifest() {
  std::vector<Endpoint> out;
  std::ifstream in(kDeviceManifest);
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream row(line);
    Endpoint e;
    if (!std::getline(row, e.id, '\t')) continue;
    if (!std::getline(row, e.label, '\t')) continue;
    if (!std::getline(row, e.endpoint)) continue;
    if (!e.id.empty() && !e.endpoint.empty()) out.push_back(std::move(e));
  }
  return out;
}

inline std::string primary_camera_endpoint() {
  const auto endpoints = read_manifest();
  return endpoints.empty() ? std::string{} : endpoints.front().endpoint;
}
}
