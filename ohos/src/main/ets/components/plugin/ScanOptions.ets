/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { ble, access, connection } from '@kit.ConnectivityKit'

export class ScanOptions implements ble.ScanOptions {
  public interval?: number;
  public dutyMode?: ble.ScanDuty;
  public matchMode?: ble.MatchMode;
  public phyType?: ble.PhyType;
}


export class ScanOptionBuilder extends ScanOptions {

  setInterval(interval: number) {
    this.interval = interval
  }

  setDutyMode(dutyMode: ble.ScanDuty) {
    this.dutyMode = dutyMode;
  }

  setMatchMode(matchMode: ble.MatchMode) {
    this.matchMode = matchMode;
  }

  setPhyType(phyType: ble.PhyType) {
    this.phyType = phyType;
  }
}
