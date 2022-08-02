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

#include "internal/platform/credential_storage.h"

namespace location {
namespace nearby {

using ::nearby::presence::proto::PrivateCredential;
using ::nearby::presence::proto::PublicCredential;

void CredentialStorage::SavePrivateCredentials(
    std::string account_name,
    std::vector<PrivateCredential>& private_credentials,
    api::SaveCredentialsResultCallback callback) {
  return impl_->SavePrivateCredentials(account_name, private_credentials,
                                       callback);
}

void CredentialStorage::SavePublicCredentials(
    std::string account_name, std::vector<PublicCredential>& public_credentials,
    api::PublicCredentialType public_credential_type,
    api::SaveCredentialsResultCallback callback) {
  return impl_->SavePublicCredentials(account_name, public_credentials,
                                      public_credential_type, callback);
}

void CredentialStorage::GetPrivateCredentials(
    api::CredentialSelector credential_selector,
    api::GetPrivateCredentialsResultCallback callback) {
  return impl_->GetPrivateCredentials(credential_selector, callback);
}

void CredentialStorage::GetPublicCredentials(
    api::CredentialSelector credential_selector,
    api::PublicCredentialType public_credential_type,
    api::GetPublicCredentialsResultCallback callback) {
  return impl_->GetPublicCredentials(credential_selector,
                                     public_credential_type, callback);
}

}  // namespace nearby
}  // namespace location
