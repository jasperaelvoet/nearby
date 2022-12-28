// Copyright 2022 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef THIRD_PARTY_NEARBY_INTERNAL_PLATFORM_IMPLEMENTATION_HTTP_LOADER_H_
#define THIRD_PARTY_NEARBY_INTERNAL_PLATFORM_IMPLEMENTATION_HTTP_LOADER_H_

#include <map>
#include <string>

namespace location {
namespace nearby {
namespace api {

struct WebRequest {
  std::string url;
  std::string method;
  std::multimap<std::string, std::string> headers;
  std::string body;
};

struct WebResponse {
  int status_code;
  std::string status_text;
  std::multimap<std::string, std::string> headers;
  std::string body;
};

}  // namespace api
}  // namespace nearby
}  // namespace location

#endif  // THIRD_PARTY_NEARBY_INTERNAL_PLATFORM_IMPLEMENTATION_HTTP_LOADER_H_
