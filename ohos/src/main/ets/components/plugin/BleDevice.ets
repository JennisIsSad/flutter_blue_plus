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

const TAG: string = 'BleDevice';
const BLE_ADV_TYPE_FLAG = 0x01;
const BLE_ADV_TYPE_16_BIT_SERVICE_UUIDS_INCOMPLETE = 0x02;
const BLE_ADV_TYPE_16_BIT_SERVICE_UUIDS_COMPLETE = 0x03;
const BLE_ADV_TYPE_32_BIT_SERVICE_UUIDS_INCOMPLETE = 0x04;
const BLE_ADV_TYPE_32_BIT_SERVICE_UUIDS_COMPLETE = 0x05;
const BLE_ADV_TYPE_128_BIT_SERVICE_UUIDS_INCOMPLETE = 0x06;
const BLE_ADV_TYPE_128_BIT_SERVICE_UUIDS_COMPLETE = 0x07;
const BLE_ADV_TYPE_LOCAL_NAME_SHORT = 0x08;
const BLE_ADV_TYPE_LOCAL_NAME_COMPLETE = 0x09;
const BLE_ADV_TYPE_TX_POWER_LEVEL = 0x0A;
const BLE_ADV_TYPE_16_BIT_SERVICE_SOLICITATION_UUIDS = 0x14;
const BLE_ADV_TYPE_128_BIT_SERVICE_SOLICITATION_UUIDS = 0x15;
const BLE_ADV_TYPE_32_BIT_SERVICE_SOLICITATION_UUIDS = 0x1F;
const BLE_ADV_TYPE_16_BIT_SERVICE_DATA = 0x16;
const BLE_ADV_TYPE_32_BIT_SERVICE_DATA = 0x20;
const BLE_ADV_TYPE_128_BIT_SERVICE_DATA = 0x21;
const BLE_ADV_TYPE_MANUFACTURER_SPECIFIC_DATA = 0xFF;

const BLUETOOTH_UUID_16_BIT_LENGTH = 2;
const BLUETOOTH_UUID_32_BIT_LENGTH = 4;
const BLUETOOTH_UUID_128_BIT_LENGTH = 16;

const BLUETOOTH_MANUFACTURE_ID_LENGTH = 2;

export default class BleDevice {
  mDeviceName: string = '';
  mDeviceId: string = '';
  //mac
  mScanRecord: Uint8Array = new Uint8Array();
  mRssi: number = 0;
  mTimestampNanos: number = 0;
  connectable: boolean = false;

  mTxPowerLevel:number = 0;
  mServiceUuids:string[] = [];
  mManufactureData:Map<number, string> = new Map<number, string>();


  public constructor(deviceId: string, name: string, rssi?: number, scanRecord ?: Uint8Array, timestampNanos ?: number,
    connectable?: boolean) {
    this.mDeviceName = name;
    this.mDeviceId = deviceId;
    if (connectable != undefined) {
      this.connectable = connectable;
    }
    if (scanRecord) {
      this.mScanRecord = scanRecord;
      this.parseScanResult(scanRecord);
    }
    if (rssi) {
      this.mRssi = rssi;
    }
    if (timestampNanos) {
      this.mTimestampNanos = timestampNanos;
    }
  }

  public static copy(device: BleDevice): BleDevice {
    return new BleDevice(device.mDeviceId, device.mDeviceName, device.mRssi, device.mScanRecord,
      device.mTimestampNanos);
  }

  public getName(): string {
    return this.mDeviceName;
  }

  public setName(name: string): void {
    this.mDeviceName = name;
  }

  public getMac(): string {
    return this.mDeviceId;
  }

  public getKey(): string {
    if (this.mDeviceName != null && this.mDeviceId != null) {
      return this.mDeviceName + this.mDeviceId;
    }
    return "";
  }

  //  public getDevice(): bluetooth.GattClientDevice {
  //    return bluetooth.BLE.createGattClientDevice(this.mDeviceId);
  //  }
  //
  //  public setDevice(device: bluetooth.GattClientDevice) {
  //    this.mDevice = device;
  //  }

  public getConnectable(): boolean {
    return this.connectable;
  }

  public setConnectable(connectable: boolean) {
    this.connectable = connectable;
  }

  public getScanRecord(): Uint8Array {
    return this.mScanRecord;
  }

  public setScanRecord(scanRecord: Uint8Array) {
    this.mScanRecord = scanRecord;
  }

  public getRssi(): number {
    return this.mRssi;
  }

  public setRssi(rssi: number) {
    this.mRssi = rssi;
  }

  public getTimestampNanos(): number {
    return this.mTimestampNanos;
  }

  public setTimestampNanos(timestampNanos: number) {
    this.mTimestampNanos = timestampNanos;
  }

  public getTxPowerLevel(): number {
    return this.mTxPowerLevel;
  }

  public getServiceUuids(): string[] {
    return this.mServiceUuids;
  }

  public getManufactureData(): Map<number, string> {
    return this.mManufactureData;
  }


  private parseScanResult(data: Uint8Array) {
    let advData = data;
    if (advData.byteLength == 0) {
      console.warn(TAG, 'nothing, adv data length is 0');
      return;
    }
    console.info(TAG, 'advData: ' + JSON.stringify(advData));

    let advFlags: number = -1;
    let txPowerLevel: number = -1;
    let localName: string = "";
    let serviceUuids: string[] = [];
    let serviceSolicitationUuids: string[] = [];
    let serviceDatas: Record<string, Uint8Array> = {};
    let manufactureSpecificDatas: Map<number, string> = new Map<number, string>();

    let curPos = 0;
    while (curPos < advData.byteLength) {
      let length = advData[curPos++];
      if (length == 0) {
        break;
      }
      let advDataLength = length - 1;
      let advDataType = advData[curPos++];
      switch (advDataType) {
        case BLE_ADV_TYPE_FLAG:
          advFlags = advData[curPos];
          break;
        case BLE_ADV_TYPE_LOCAL_NAME_SHORT:
        case BLE_ADV_TYPE_LOCAL_NAME_COMPLETE:
          localName = advData.slice(curPos, curPos + advDataLength).toString();
          break;
        case BLE_ADV_TYPE_TX_POWER_LEVEL:
          txPowerLevel = advData[curPos];
          this.mTxPowerLevel = txPowerLevel;
          break;
        case BLE_ADV_TYPE_16_BIT_SERVICE_UUIDS_INCOMPLETE:
        case BLE_ADV_TYPE_16_BIT_SERVICE_UUIDS_COMPLETE:
          this.parseServiceUuid(BLUETOOTH_UUID_16_BIT_LENGTH, curPos, advDataLength, advData, serviceUuids);
          break;
        case BLE_ADV_TYPE_32_BIT_SERVICE_UUIDS_INCOMPLETE:
        case BLE_ADV_TYPE_32_BIT_SERVICE_UUIDS_COMPLETE:
          this.parseServiceUuid(BLUETOOTH_UUID_32_BIT_LENGTH, curPos, advDataLength, advData, serviceUuids);
          break;
        case BLE_ADV_TYPE_128_BIT_SERVICE_UUIDS_INCOMPLETE:
        case BLE_ADV_TYPE_128_BIT_SERVICE_UUIDS_COMPLETE:
          this.parseServiceUuid(BLUETOOTH_UUID_128_BIT_LENGTH, curPos, advDataLength, advData, serviceUuids);
          break;
        case BLE_ADV_TYPE_16_BIT_SERVICE_SOLICITATION_UUIDS:
          this.parseServiceSolicitationUuid(BLUETOOTH_UUID_16_BIT_LENGTH, curPos, advDataLength,
            advData, serviceSolicitationUuids);
          break;
        case BLE_ADV_TYPE_32_BIT_SERVICE_SOLICITATION_UUIDS:
          this.parseServiceSolicitationUuid(BLUETOOTH_UUID_32_BIT_LENGTH, curPos, advDataLength,
            advData, serviceSolicitationUuids);
          break;
        case BLE_ADV_TYPE_128_BIT_SERVICE_SOLICITATION_UUIDS:
          this.parseServiceSolicitationUuid(BLUETOOTH_UUID_128_BIT_LENGTH, curPos, advDataLength,
            advData, serviceSolicitationUuids);
          break;
        case BLE_ADV_TYPE_16_BIT_SERVICE_DATA:
          this.parseServiceData(BLUETOOTH_UUID_16_BIT_LENGTH, curPos, advDataLength, advData, serviceDatas);
          break;
        case BLE_ADV_TYPE_32_BIT_SERVICE_DATA:
          this.parseServiceData(BLUETOOTH_UUID_32_BIT_LENGTH, curPos, advDataLength, advData, serviceDatas);
          break;
        case BLE_ADV_TYPE_128_BIT_SERVICE_DATA:
          this.parseServiceData(BLUETOOTH_UUID_128_BIT_LENGTH, curPos, advDataLength, advData, serviceDatas);
          break;
        case BLE_ADV_TYPE_MANUFACTURER_SPECIFIC_DATA:
          this.parseManufactureData(curPos, advDataLength, advData, manufactureSpecificDatas);
          break;
        default:
          break;
      }
      curPos += advDataLength;
    }
  }

  private parseServiceUuid(uuidLength: number, curPos: number, advDataLength: number,
    advData: Uint8Array, serviceUuids: string[]) {
    while (advDataLength > 0) {
      let tmpData: Uint8Array = advData.slice(curPos, curPos + uuidLength);
      serviceUuids.push(this.getUuidFromUint8Array(uuidLength, tmpData));
      advDataLength -= uuidLength;
      curPos += uuidLength;
    }
    this.mServiceUuids = serviceUuids;
  }

  private parseServiceSolicitationUuid(uuidLength: number, curPos: number, advDataLength: number,
    advData: Uint8Array, serviceSolicitationUuids: string[]) {
    while (advDataLength > 0) {
      let tmpData: Uint8Array = advData.slice(curPos, curPos + uuidLength);
      serviceSolicitationUuids.push(this.getUuidFromUint8Array(uuidLength, tmpData));
      advDataLength -= uuidLength;
      curPos += uuidLength;
    }
  }

  private getUuidFromUint8Array(uuidLength: number, uuidData: Uint8Array): string {
    let uuid = "";
    let temp: string = "";
    for (let i = uuidLength - 1; i > -1; i--) {
      temp += uuidData[i].toString(16).padStart(2, "0");
    }
    switch (uuidLength) {
      case BLUETOOTH_UUID_16_BIT_LENGTH:
        uuid = `0000${temp}-0000-1000-8000-00805F9B34FB`;
        break;
      case BLUETOOTH_UUID_32_BIT_LENGTH:
        uuid = `${temp}-0000-1000-8000-00805F9B34FB`;
        break;
      case BLUETOOTH_UUID_128_BIT_LENGTH:
        uuid = `${temp.substring(0, 8)}-${temp.substring(8, 12)}-${temp.substring(12, 16)}-${temp.substring(16, 20)}-${temp.substring(20, 32)}`;
        break;
      default:
        break;
    }
    return uuid;
  }

  private parseServiceData(uuidLength: number, curPos: number, advDataLength: number,
    advData: Uint8Array, serviceDatas: Record<string, Uint8Array>) {
    let tmpUuid: Uint8Array = advData.slice(curPos, curPos + uuidLength);
    let tmpValue: Uint8Array = advData.slice(curPos + uuidLength, curPos + advDataLength);
    serviceDatas[tmpUuid.toString()] = tmpValue;
  }

  private parseManufactureData(curPos: number, advDataLength: number,
    advData: Uint8Array, manufactureSpecificDatas: Map<number, string>) {
    let manufactureId: number = (advData[curPos + 1] << 8) + advData[curPos];
    let tmpValue: Uint8Array = advData.slice(curPos + BLUETOOTH_MANUFACTURE_ID_LENGTH, curPos + advDataLength);

    // 将数据转换为十六进制字符串
    let hexString = Array.from(tmpValue).map(byte => byte.toString(16).padStart(2, '0')).join('');

    // 如果已存在相同的 manufactureId，则拼接新数据
    if (manufactureSpecificDatas.has(manufactureId)) {
      let existingData = manufactureSpecificDatas.get(manufactureId)!;
      manufactureSpecificDatas.set(manufactureId, existingData + hexString);
    } else {
      manufactureSpecificDatas.set(manufactureId, hexString);
    }

    this.mManufactureData = manufactureSpecificDatas;
  }
}