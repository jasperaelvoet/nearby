// Copyright 2021 Google LLC
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
#ifndef CORE_DISCOVERY_OPTIONS_H_
#define CORE_DISCOVERY_OPTIONS_H_
#include <string>

#include "core/medium_selector.h"
#include "core/options_base.h"
#include "core/power_level.h"
#include "core/strategy.h"
#include "platform/base/byte_array.h"
#include "proto/connections_enums.pb.h"

namespace location {
namespace nearby {
namespace connections {

// Feature On/Off switch for mediums.
using BooleanMediumSelector = MediumSelector<bool>;

// Connection Options: used for both Advertising and Discovery.
// All fields are mutable, to make the type copy-assignable.
struct DiscoveryOptions : OptionsBase {
  bool auto_upgrade_bandwidth;
  bool enforce_topology_constraints;
  int keep_alive_interval_millis = 0;
  int keep_alive_timeout_millis = 0;

  // Whether this is intended to be used in conjunction with InjectEndpoint().
  bool is_out_of_band_connection = false;
  std::string fast_advertisement_service_uuid;

  // Returns a copy and normalizes allowed mediums:
  // (1) If is_out_of_band_connection is true, verifies that there is only one
  //     medium allowed, defaulting to only Bluetooth if unspecified.
  // (2) If no mediums are allowed, allow all mediums.
  DiscoveryOptions CompatibleOptions() const;
};

}  // namespace connections
}  // namespace nearby
}  // namespace location

#endif  // CORE_DISCOVERY_OPTIONS_H_
