#pragma once
#include <algorithm>
#include <cctype>
#include <fstream>
#include <map>
#include <string>
#include "protocol.hpp"
namespace remold {
class Config {
 public:
  explicit Config(const std::string& path=kConfigPath){load(path);}
  std::string get(const std::string& key,const std::string& fallback="") const {auto it=v_.find(key);return it==v_.end()?fallback:it->second;}
  int get_int(const std::string& key,int fallback) const {try{return std::stoi(get(key,std::to_string(fallback)));}catch(...){return fallback;}}
  bool get_bool(const std::string& key,bool fallback) const {auto s=get(key,fallback?"true":"false");std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return std::tolower(c);});return s=="1"||s=="true"||s=="yes"||s=="on";}
 private:
  std::map<std::string,std::string> v_;
  static std::string trim(std::string s){auto notsp=[](unsigned char c){return !std::isspace(c);};s.erase(s.begin(),std::find_if(s.begin(),s.end(),notsp));s.erase(std::find_if(s.rbegin(),s.rend(),notsp).base(),s.end());return s;}
  void load(const std::string& path){std::ifstream f(path);std::string line;while(std::getline(f,line)){line=trim(line);if(line.empty()||line[0]=='#')continue;auto p=line.find('=');if(p==std::string::npos)continue;v_[trim(line.substr(0,p))]=trim(line.substr(p+1));}}
};
}
