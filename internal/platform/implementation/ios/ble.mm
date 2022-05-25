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

#import "internal/platform/implementation/ios/ble.h"

#include <CoreBluetooth/CoreBluetooth.h>
#include <functional>
#include <string>
#include <utility>

#include "internal/platform/implementation/ble_v2.h"
#import "internal/platform/implementation/ios/Mediums/Ble/GNCMBleCentral.h"
#import "internal/platform/implementation/ios/Mediums/Ble/GNCMBlePeripheral.h"
#include "internal/platform/implementation/ios/bluetooth_adapter.h"
#include "internal/platform/implementation/ios/utils.h"
#import "GoogleToolboxForMac/GTMLogger.h"

namespace location {
namespace nearby {
namespace ios {

namespace {

CBAttributePermissions PermissionToCBPermissions(
    const std::vector<api::ble_v2::GattCharacteristic::Permission>& permissions) {
  CBAttributePermissions characteristPermissions = 0;
  for (const auto& permission : permissions) {
    switch (permission) {
      case api::ble_v2::GattCharacteristic::Permission::kRead:
        characteristPermissions |= CBAttributePermissionsReadable;
        break;
      case api::ble_v2::GattCharacteristic::Permission::kWrite:
        characteristPermissions |= CBAttributePermissionsWriteable;
        break;
      case api::ble_v2::GattCharacteristic::Permission::kLast:
      case api::ble_v2::GattCharacteristic::Permission::kUnknown:
      default:;  // fall through
    }
  }
  return characteristPermissions;
}

CBCharacteristicProperties PropertiesToCBProperties(
    const std::vector<api::ble_v2::GattCharacteristic::Property>& properties) {
  CBCharacteristicProperties characteristicProperties = 0;
  for (const auto& property : properties) {
    switch (property) {
      case api::ble_v2::GattCharacteristic::Property::kRead:
        characteristicProperties |= CBCharacteristicPropertyRead;
        break;
      case api::ble_v2::GattCharacteristic::Property::kWrite:
        characteristicProperties |= CBCharacteristicPropertyWrite;
        break;
      case api::ble_v2::GattCharacteristic::Property::kIndicate:
        characteristicProperties |= CBCharacteristicPropertyIndicate;
        break;
      case api::ble_v2::GattCharacteristic::Property::kLast:
      case api::ble_v2::GattCharacteristic::Property::kUnknown:
      default:;  // fall through
    }
  }
  return characteristicProperties;
}

}  // namespace

using ::location::nearby::api::ble_v2::BleAdvertisementData;
using ::location::nearby::api::ble_v2::TxPowerLevel;
using ScanCallback = ::location::nearby::api::ble_v2::BleMedium::ScanCallback;

/** InputStream that reads from GNCMConnection. */
BleInputStream::BleInputStream()
    : newDataPackets_([NSMutableArray array]),
      accumulatedData_([NSMutableData data]),
      condition_([[NSCondition alloc] init]) {
  // Create the handlers of incoming data from the remote endpoint.
  connectionHandlers_ = [GNCMConnectionHandlers
      payloadHandler:^(NSData* data) {
        [condition_ lock];
        // Add the incoming data to the data packet array to be processed in read() below.
        [newDataPackets_ addObject:data];
        [condition_ signal];
        [condition_ unlock];
      }
      disconnectedHandler:^{
        [condition_ lock];
        // Release the data packet array, meaning the stream has been closed or severed.
        newDataPackets_ = nil;
        [condition_ signal];
        [condition_ unlock];
      }];
}

BleInputStream::~BleInputStream() {
  NSCAssert(!newDataPackets_, @"BleInputStream not closed before destruction");
}

ExceptionOr<ByteArray> BleInputStream::Read(std::int64_t size) {
  // Block until either (a) the connection has been closed, (b) we have enough data to return.
  NSData* dataToReturn;
  [condition_ lock];
  while (true) {
    // Check if the stream has been closed or severed.
    if (!newDataPackets_) break;

    if (newDataPackets_.count > 0) {
      // Add the packet data to the accumulated data.
      for (NSData* data in newDataPackets_) {
        if (data.length > 0) {
          [accumulatedData_ appendData:data];
        }
      }
      [newDataPackets_ removeAllObjects];
    }

    if ((size == -1) && (accumulatedData_.length > 0)) {
      // Return all of the data.
      dataToReturn = accumulatedData_;
      accumulatedData_ = [NSMutableData data];
      break;
    } else if (accumulatedData_.length > 0) {
      // Return up to |size| bytes of the data.
      std::int64_t sizeToReturn = (accumulatedData_.length < size) ? accumulatedData_.length : size;
      NSRange range = NSMakeRange(0, (NSUInteger)sizeToReturn);
      dataToReturn = [accumulatedData_ subdataWithRange:range];
      [accumulatedData_ replaceBytesInRange:range withBytes:nil length:0];
      break;
    }

    [condition_ wait];
  }
  [condition_ unlock];

  if (dataToReturn) {
    GTMLoggerInfo(@"[NEARBY] Input stream: Received data of size: %lu",
                  (unsigned long)dataToReturn.length);
    return ExceptionOr<ByteArray>(ByteArrayFromNSData(dataToReturn));
  } else {
    return ExceptionOr<ByteArray>{Exception::kIo};
  }
}

Exception BleInputStream::Close() {
  // Unblock pending read operation.
  [condition_ lock];
  newDataPackets_ = nil;
  [condition_ signal];
  [condition_ unlock];
  return {Exception::kSuccess};
}

/** OutputStream that writes to GNCMConnection. */
BleOutputStream::~BleOutputStream() {
  NSCAssert(!connection_, @"BleOutputStream not closed before destruction");
}

Exception BleOutputStream::Write(const ByteArray& data) {
  [condition_ lock];
  GTMLoggerInfo(@"[NEARBY] Sending data of size: %lu",
                (unsigned long)NSDataFromByteArray(data).length);

  NSMutableData* packet = [NSMutableData dataWithData:NSDataFromByteArray(data)];

  // Send the data, blocking until the completion handler is called.
  __block GNCMPayloadResult sendResult = GNCMPayloadResultFailure;
  __block bool isComplete = NO;
  NSCondition* condition = condition_;  // don't capture |this| in completion

  // Check if connection_ is nil, then just don't wait and return as failure.
  if (connection_ != nil) {
    [connection_ sendData:packet
        progressHandler:^(size_t count) {
        }
        completion:^(GNCMPayloadResult result) {
          // Make sure we haven't already reported completion before. This prevents a crash
          // where we try leaving a dispatch group more times than we entered it.
          // b/79095653.
          if (isComplete) {
            return;
          }
          isComplete = YES;
          sendResult = result;
          [condition lock];
          [condition signal];
          [condition unlock];
        }];
    [condition_ wait];
    [condition_ unlock];
  } else {
    sendResult = GNCMPayloadResultFailure;
    [condition_ unlock];
  }

  if (sendResult == GNCMPayloadResultSuccess) {
    return {Exception::kSuccess};
  } else {
    return {Exception::kIo};
  }
}

Exception BleOutputStream::Flush() {
  // The write() function blocks until the data is received by the remote endpoint, so there's
  // nothing to do here.
  return {Exception::kSuccess};
}

Exception BleOutputStream::Close() {
  // Unblock pending write operation.
  [condition_ lock];
  connection_ = nil;
  [condition_ signal];
  [condition_ unlock];
  return {Exception::kSuccess};
}

/** BleSocket implementation.*/
BleSocket::BleSocket(id<GNCMConnection> connection)
    : input_stream_(new BleInputStream()), output_stream_(new BleOutputStream(connection)) {}

BleSocket::~BleSocket() {
  absl::MutexLock lock(&mutex_);
  DoClose();
}

bool BleSocket::IsClosed() const {
  absl::MutexLock lock(&mutex_);
  return closed_;
}

Exception BleSocket::Close() {
  absl::MutexLock lock(&mutex_);
  DoClose();
  return {Exception::kSuccess};
}

void BleSocket::DoClose() {
  if (!closed_) {
    input_stream_->Close();
    output_stream_->Close();
    closed_ = true;
  }
}

/** WifiLanServerSocket implementation. */
BleServerSocket::~BleServerSocket() {
  absl::MutexLock lock(&mutex_);
  DoClose();
}

std::unique_ptr<api::ble_v2::BleSocket> BleServerSocket::Accept() {
  absl::MutexLock lock(&mutex_);
  while (!closed_ && pending_sockets_.empty()) {
    cond_.Wait(&mutex_);
  }
  // Return early if closed.
  if (closed_) return {};

  auto remote_socket = std::move(pending_sockets_.extract(pending_sockets_.begin()).value());
  return std::move(remote_socket);
}

bool BleServerSocket::Connect(std::unique_ptr<BleSocket> socket) {
  absl::MutexLock lock(&mutex_);
  if (closed_) {
    return false;
  }
  // add client socket to the pending list
  pending_sockets_.insert(std::move(socket));
  cond_.SignalAll();
  if (closed_) {
    return false;
  }
  return true;
}

void BleServerSocket::SetCloseNotifier(std::function<void()> notifier) {
  absl::MutexLock lock(&mutex_);
  close_notifier_ = std::move(notifier);
}

Exception BleServerSocket::Close() {
  absl::MutexLock lock(&mutex_);
  return DoClose();
}

Exception BleServerSocket::DoClose() {
  bool should_notify = !closed_;
  closed_ = true;
  if (should_notify) {
    cond_.SignalAll();
    if (close_notifier_) {
      auto notifier = std::move(close_notifier_);
      mutex_.Unlock();
      // Notifier may contain calls to public API, and may cause deadlock, if
      // mutex_ is held during the call.
      notifier();
      mutex_.Lock();
    }
  }
  return {Exception::kSuccess};
}

/** BleMedium implementation. */
BleMedium::BleMedium(::location::nearby::api::BluetoothAdapter& adapter)
    : adapter_(static_cast<BluetoothAdapter*>(&adapter)) {}

bool BleMedium::StartAdvertising(
    int advertisement_id, const BleAdvertisementData& advertising_data,
    ::location::nearby::api::ble_v2::AdvertiseParameters advertise_set_parameters) {
  if (advertising_data.service_data.empty()) {
    return false;
  }
  const auto& service_uuid = advertising_data.service_data.begin()->first.Get16BitAsString();
  const ByteArray& service_data_bytes = advertising_data.service_data.begin()->second;

  if (!peripheral_) {
    peripheral_ = [[GNCMBlePeripheral alloc] init];
  }

  [peripheral_ startAdvertisingWithServiceUUID:ObjCStringFromCppString(service_uuid)
                             advertisementData:NSDataFromByteArray(service_data_bytes)];
  return true;
}

bool BleMedium::StopAdvertising(int advertisement_id) {
  peripheral_ = nil;
  return true;
}

bool BleMedium::StartScanning(const Uuid& service_uuid, TxPowerLevel tx_power_level,
                              ScanCallback scan_callback) {
  if (!central_) {
    central_ = [[GNCMBleCentral alloc] init];
  }

  [central_ startScanningWithServiceUUID:ObjCStringFromCppString(service_uuid.Get16BitAsString())
                       scanResultHandler:^(NSString* peripheralID, NSData* serviceData) {
                         BleAdvertisementData advertisement_data;
                         advertisement_data.service_data = {
                             {service_uuid, ByteArrayFromNSData(serviceData)}};
                         BlePeripheral& peripheral = adapter_->GetPeripheral();
                         peripheral.SetPeripheralId(CppStringFromObjCString(peripheralID));
                         scan_callback.advertisement_found_cb(peripheral, advertisement_data);
                       }];

  return true;
}

bool BleMedium::StopScanning() {
  central_ = nil;
  return true;
}

std::unique_ptr<api::ble_v2::GattServer> BleMedium::StartGattServer(
    api::ble_v2::ServerGattConnectionCallback callback) {
  if (!peripheral_) {
    peripheral_ = [[GNCMBlePeripheral alloc] init];
  }
  return std::make_unique<GattServer>(peripheral_);
}

std::unique_ptr<api::ble_v2::GattClient> BleMedium::ConnectToGattServer(
    api::ble_v2::BlePeripheral& peripheral, TxPowerLevel tx_power_level,
    api::ble_v2::ClientGattConnectionCallback callback) {
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block NSError* connectedError;
  BlePeripheral iosPeripheral = static_cast<BlePeripheral&>(peripheral);
  std::string peripheral_id = iosPeripheral.GetPeripheralId();
  [central_ connectGattServerWithPeripheralID:ObjCStringFromCppString(peripheral_id)
                  gattConnectionResultHandler:^(NSError* _Nullable error) {
                    connectedError = error;
                    dispatch_semaphore_signal(semaphore);
                  }];
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

  if (connectedError) {
    return nullptr;
  }
  return std::make_unique<GattClient>(central_, peripheral_id);
}

std::unique_ptr<api::ble_v2::BleServerSocket> BleMedium::OpenServerSocket(
    const std::string& service_id) {
  auto server_socket = std::make_unique<BleServerSocket>();
  server_socket->SetCloseNotifier([this, service_id]() {
    absl::MutexLock lock(&mutex_);
    server_sockets_.erase(service_id);
  });
  absl::MutexLock lock(&mutex_);
  server_sockets_.insert({service_id, server_socket.get()});
  return server_socket;
}

std::unique_ptr<api::ble_v2::BleSocket> BleMedium::Connect(const std::string& service_id,
                                                           TxPowerLevel tx_power_level,
                                                           api::ble_v2::BlePeripheral& peripheral,
                                                           CancellationFlag* cancellation_flag) {
  GNCMConnectionRequester connection_requester = nil;
  {
    absl::MutexLock lock(&mutex_);
    const auto& it = connection_requesters_.find(service_id);
    if (it == connection_requesters_.end()) {
      return {};
    }
    connection_requester = it->second;
  }

  dispatch_group_t group = dispatch_group_create();
  dispatch_group_enter(group);
  __block std::unique_ptr<BleSocket> socket;
  if (connection_requester != nil) {
    if (cancellation_flag->Cancelled()) {
      GTMLoggerError(@"[NEARBY] BLE Connect: Has been cancelled: service_id=%@",
                     ObjCStringFromCppString(service_id));
      dispatch_group_leave(group);  // unblock
      return {};
    }

    connection_requester(^(id<GNCMConnection> connection) {
      // If the connection wasn't successfully established, return a NULL socket.
      if (connection) {
        socket = std::make_unique<BleSocket>(connection);
      }

      dispatch_group_leave(group);  // unblock
      return socket != nullptr
                 ? static_cast<BleInputStream&>(socket->GetInputStream()).GetConnectionHandlers()
                 : nullptr;
    });
  }
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

  return std::move(socket);
}

bool BleMedium::IsExtendedAdvertisementsAvailable() { return false; }

// NOLINTNEXTLINE
absl::optional<api::ble_v2::GattCharacteristic> BleMedium::GattServer::CreateCharacteristic(
    const Uuid& service_uuid, const Uuid& characteristic_uuid,
    const std::vector<api::ble_v2::GattCharacteristic::Permission>& permissions,
    const std::vector<api::ble_v2::GattCharacteristic::Property>& properties) {
  api::ble_v2::GattCharacteristic characteristic = {.uuid = characteristic_uuid,
                                                    .service_uuid = service_uuid,
                                                    .permissions = permissions,
                                                    .properties = properties};
  [peripheral_
      addCBServiceWithUUID:[CBUUID
                               UUIDWithString:ObjCStringFromCppString(
                                                  characteristic.service_uuid.Get16BitAsString())]];
  [peripheral_
      addCharacteristic:[[CBMutableCharacteristic alloc]
                            initWithType:[CBUUID UUIDWithString:ObjCStringFromCppString(std::string(
                                                                    characteristic.uuid))]
                              properties:PropertiesToCBProperties(characteristic.properties)
                                   value:nil
                             permissions:PermissionToCBPermissions(characteristic.permissions)]];
  return characteristic;
}

bool BleMedium::GattServer::UpdateCharacteristic(
    const api::ble_v2::GattCharacteristic& characteristic,
    const location::nearby::ByteArray& value) {
  [peripheral_ updateValue:NSDataFromByteArray(value)
         forCharacteristic:[CBUUID UUIDWithString:ObjCStringFromCppString(
                                                      std::string(characteristic.uuid))]];
  return true;
}

void BleMedium::GattServer::Stop() { [peripheral_ stopGATTService]; }

bool BleMedium::GattClient::DiscoverServiceAndCharacteristics(
    const Uuid& service_uuid, const std::vector<Uuid>& characteristic_uuids) {
  // Discover all characteristics that may contain the advertisement.
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  gatt_characteristic_values_.clear();
  CBUUID* serviceUUID = [CBUUID UUIDWithString:ObjCStringFromCppString(std::string(service_uuid))];

  absl::flat_hash_map<std::string, Uuid> gatt_characteristics;
  NSMutableArray<CBUUID*>* characteristicUUIDs =
      [NSMutableArray arrayWithCapacity:characteristic_uuids.size()];
  for (const auto& characteristic_uuid : characteristic_uuids) {
    [characteristicUUIDs addObject:[CBUUID UUIDWithString:ObjCStringFromCppString(
                                                              std::string(characteristic_uuid))]];
    gatt_characteristics.insert({std::string(characteristic_uuid), characteristic_uuid});
  }

  [central_ discoverGattService:serviceUUID
            gattCharacteristics:characteristicUUIDs
                   peripheralID:ObjCStringFromCppString(peripheral_id_)
      gattDiscoverResultHandler:^(NSDictionary<CBUUID*, NSData*>* _Nullable characteristicValues) {
        if (characteristicValues != nil) {
          for (CBUUID* charUuid in characteristicValues) {
            Uuid characteristic_uuid;
            auto const& it =
                gatt_characteristics.find(CppStringFromObjCString(charUuid.UUIDString));
            if (it == gatt_characteristics.end()) continue;

            api::ble_v2::GattCharacteristic characteristic = {.uuid = it->second,
                                                              .service_uuid = service_uuid};
            gatt_characteristic_values_.insert(
                {characteristic,
                 ByteArrayFromNSData([characteristicValues objectForKey:charUuid])});
          }
        }

        dispatch_semaphore_signal(semaphore);
      }];

  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

  if (gatt_characteristic_values_.empty()) {
    return false;
  }
  return true;
}

// NOLINTNEXTLINE
absl::optional<api::ble_v2::GattCharacteristic> BleMedium::GattClient::GetCharacteristic(
    const Uuid& service_uuid, const Uuid& characteristic_uuid) {
  api::ble_v2::GattCharacteristic characteristic = {.uuid = characteristic_uuid,
                                                    .service_uuid = service_uuid};
  auto const it = gatt_characteristic_values_.find(characteristic);
  if (it == gatt_characteristic_values_.end()) {
    return absl::nullopt;  // NOLINT
  }
  return it->first;
}

// NOLINTNEXTLINE
absl::optional<ByteArray> BleMedium::GattClient::ReadCharacteristic(
    const api::ble_v2::GattCharacteristic& characteristic) {
  auto const it = gatt_characteristic_values_.find(characteristic);
  if (it == gatt_characteristic_values_.end()) {
    return absl::nullopt;  // NOLINT
  }
  return it->second;
}

bool BleMedium::GattClient::WriteCharacteristic(
    const api::ble_v2::GattCharacteristic& characteristic, const ByteArray& value) {
  // No op.
  return false;
}

void BleMedium::GattClient::Disconnect() {
  [central_ disconnectGattServiceWithPeripheralID:ObjCStringFromCppString(peripheral_id_)];
}

}  // namespace ios
}  // namespace nearby
}  // namespace location
