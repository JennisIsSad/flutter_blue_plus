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
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  AbilityAware,
  AbilityPluginBinding,
} from '@ohos/flutter_ohos';
import UIAbility from '@ohos.app.ability.UIAbility'
import { ble, connection, constant } from '@kit.ConnectivityKit';
import { List } from '@kit.ArkTS';
import { ScanOptions, ScanOptionBuilder } from "./ScanOptions"
import { abilityAccessCtrl, bundleManager, Permissions, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import access from '@ohos.bluetooth.access';
import BleDevice from './BleDevice'
import HexUtil from './HexUtil'
import { worker } from '@kit.ArkTS';
import TextUtils from "./TextUtils"
import util from '@ohos.util'

type byte = number;
const CCCD: string = "2902";


/** FlutterBluePlusPlugin **/
export default class FlutterBluePlusPlugin implements FlutterPlugin, MethodCallHandler {
  public readonly ENABLE_NOTIFICATION_VALUE: byte[] = [0x01, 0x00];
  public readonly ENABLE_INDICATION_VALUE: byte[] = [0x02, 0x00];
  public readonly DISABLE_NOTIFICATION_VALUE: byte[] = [0x00, 0x00];
  private workerInstance = new worker.ThreadWorker('./src/main/ets/workers/Worker.ets');
  private channel: MethodChannel | null = null;
  private static TAG: string = "[FBP-Ohos]";
  private context: Context = getContext(this);
  private pluginBinding: FlutterPluginBinding | null = null;
  private abilityPluginBinding: AbilityPluginBinding | null = null;
  private mConnectedDevices: Map<string, ble.GattClientDevice> = new Map<string, ble.GattClientDevice>();
  private mCurrentlyConnectingDevices: Map<string, ble.GattClientDevice> = new Map();
  private mBondingDevices: Map<string, ble.GattClientDevice> = new Map();
  private mMtu: Map<string, number> = new Map();
  private mAutoConnected: Map<string, ble.GattClientDevice> = new Map();
  private mWriteChr: Map<string, string> = new Map();
  private mWriteDesc: Map<string, string> = new Map();
  private operationsOnPermission: Map<number, (granted: boolean, permission: string) => void> = new Map();
  private lastEventId: number = 1452;
  private mIsScanning: boolean = false;
  private clientDevice: ble.GattClientDevice | null = null;
  private remoteId: string | null = null
  private mScanFilters: Map<string, Object> = new Map();
  private mAdvSeen: Map<string, string> = new Map();
  private mScanCounts: Map<string, number> = new Map();
  private logLevel: LogLevel = LogLevel.DEBUG; // 默认日志级别
  private readonly TAG: string = "FBP_OHOS"; // 日志标签
  private readonly DOMAIN: number = 0x1234; // 假定的日志域
  public FlutterBluePlusPlugin() {
  }


  constructor() {

  }

  // 设置日志级别
  setLogLevel(level: LogLevel): void {
    this.logLevel = level;
  }

  public log(level: LogLevel, message: string, ...args: (string | number | boolean | object | undefined)[]): void {
    if (level < this.logLevel) {
      return;
    }

    const formattedMessage = `[${this.TAG}] ${message}`;
    switch (level) {
      case LogLevel.DEBUG:
        hilog.debug(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
      case LogLevel.INFO:
        hilog.info(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
      case LogLevel.WARN:
        hilog.warn(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
      case LogLevel.ERROR:
        hilog.error(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
      case LogLevel.VERBOSE:
        hilog.fatal(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
      default:
        hilog.debug(this.DOMAIN, this.TAG, formattedMessage, ...args);
        break;
    }
  }

  getUniqueClassName(): string {
    return "FlutterBluePlusPlugin"
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.log(LogLevel.DEBUG, 'onAttachedToEngine');
    this.pluginBinding = binding;
    this.context = this.pluginBinding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_blue_plus/methods");
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.log(LogLevel.DEBUG, 'onDetachedFromEngine');
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null)
    }
  }

  onAttachedToAbility(binding: AbilityPluginBinding) {
    this.log(LogLevel.DEBUG, 'onAttachedToAbility');
    connection.on('bondStateChange', (data: connection.BondStateParam) => {
      let gatt: ble.GattClientDevice = ble.createGattClientDevice(data.deviceId);
      if (data.state == connection.BondState.BOND_STATE_BONDING) {
        this.mBondingDevices.set(data.deviceId, gatt);
      } else {
        this.mBondingDevices.delete(data.deviceId);
      }
      let map: Map<string, string | number | null> = new Map();
      map.set("remote_id", data.deviceId);
      map.set("bond_state", this.bmBondStateEnum(data.state));
      map.set("prev_state", null);
      this.channel?.invokeMethod("OnBondStateChanged", map)
    });
    this.abilityPluginBinding = binding;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      this.log(LogLevel.DEBUG, 'onMethodCall: ' + call.method);
      switch (call.method) {
        case "flutterRestart": {
          result.success(this.mConnectedDevices.size)
          access.on('stateChange', (data: access.BluetoothState) => {
            this.onReceiveEvent(data)
          });
          let checkPermission: Permissions = "ohos.permission.ACCESS_BLUETOOTH";
          if (!this.checkSelfPermission(checkPermission)) {
            let permissions = new Array<Permissions>();
            permissions.push("ohos.permission.ACCESS_BLUETOOTH");
            this.ensurePermissions(permissions, result);
          }
          this.disconnectAllDevices("flutterRestart");
          this.log(LogLevel.DEBUG, "connectedPeripherals: " + this.mConnectedDevices.size);
          break;
        }
        case "connectedCount": {
          this.log(LogLevel.DEBUG, "connectedPeripherals: " + this.mConnectedDevices.size, null);
          if (this.mConnectedDevices.size == 0) {
            hilog.debug(LogLevel.DEBUG, "Hot Restart: complete", null);
          }
          result.success(this.mConnectedDevices.size);
          break;
        }
        case "setOptions": {
          result.success(this.mConnectedDevices);
          break;
        }
        case "getAdapterState": {
          try {
            let accessNum: number = -1;
            let checkPermission: Permissions = "ohos.permission.ACCESS_BLUETOOTH";
            let isPermission: boolean = await this.checkSelfPermission(checkPermission);
            this.log(LogLevel.DEBUG, "checkSelfPermission: " + isPermission);
            if (isPermission) {
              let permissions = new Array<Permissions>();
              permissions.push("ohos.permission.ACCESS_BLUETOOTH");
              await this.ensurePermissions(permissions, result);
            } else {
              accessNum = access.getState();
              this.log(LogLevel.DEBUG, "accessNum: " + accessNum);
              let map: Map<string, number> = new Map();
              map.set("adapter_state", this.bmAdapterStateEnum(accessNum))
              result.success(map);
            }
            this.log(LogLevel.DEBUG, "getAdapterState Access Num:  " + accessNum);
          } catch (e) {
            this.log(LogLevel.DEBUG, "getAdapterState error: " + JSON.stringify(e));
          }
          break;
        }
        case "getSystemDevices": {
          try {
            let devices: Array<string> = ble.getConnectedBLEDevices();
            let devList: List<Map<string, string>> = new List<Map<string, string>>();
            devices.forEach(device => devList.add(this.bmBluetoothDevice(device)))
            let response: Map<string, object> = new Map();
            response.set("devices", devList);
            result.success(response);
          } catch (err) {
            console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' +
            (err as BusinessError).message);
          }
          break;
        }
        case "turnOn": {
          let permissions = new Array<Permissions>();
          permissions.push("ohos.permission.ACCESS_BLUETOOTH");
          this.ensurePermissions(permissions, result);

          if (access.getState() == 2) {
            result.success(false); // no work to do
            return;
          } else if (access.getState() == 0) {
            access.enableBluetooth();
            result.success(true);
          }
          break;
        }
        case "turnOff": {
          let checkPermission: Permissions = "ohos.permission.ACCESS_BLUETOOTH";
          let isPermission: boolean = await this.checkSelfPermission(checkPermission);
          console.info("---checkSelfPermission" + isPermission)
          if (isPermission) {
            let permissions = new Array<Permissions>();
            permissions.push("ohos.permission.ACCESS_BLUETOOTH");
            await this.ensurePermissions(permissions, result);
          } else {
            if (!this.isAdapterOn()) {
              result.success(true); // no work to do
              return;
            }
            let disableFlag: boolean = true;
            try {
              access.disableBluetooth();
            } catch (e) {
              disableFlag = false;
            }
            result.success(disableFlag);
            break;
          }
        }
        case "startScan": {
          try {
            let data: Map<string, Object> = call.args;
            let withServices: List<string> = data.get("with_services") as List<string>;
            let withRemoteIds: List<string> = data.get("with_remote_ids") as List<string>;
            let withNames: List<string> = data.get("with_names") as List<string>;
            let withKeywords: List<string> = data.get("with_keywords") as List<string>;
            let withMsd: List<object> = data.get("with_services") as List<object>;
            let withServiceData: List<object> = data.get("with_service_data") as List<object>;
            let continuousUpdates: boolean = data.get("continuous_updates") as ESObject;
            let androidScanMode: number = data.get("android_scan_mode") as ESObject;
            let androidUsesFineLocation: boolean = data.get("android_uses_fine_location") as ESObject;
            // let permissions = new Array<Permissions>();
            // permissions.push("ohos.permission.ACCESS_BLUETOOTH");
            // this.ensurePermissions(permissions, result);
            let isAdapterOn: boolean = this.isAdapterOn();
            if (isAdapterOn == false) {
              result.error("startScan", "系统蓝牙没有打开", null);
              return;
            }
            let filterArray: ble.ScanFilter[] = [];
            for (let i = 0; i < withServices.length; i++) {
              let filter: ble.ScanFilter = {
                serviceUuid: withServices[i]
              };
              filterArray.push(filter);
            }
            let scanOption: ble.ScanOptions = {
              dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
              matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
              interval: 0
            };

            this.workerInstance.postMessage("123");
            ble.on("BLEDeviceFind", async (data) => {
              await this.scanCallback(data);
            });
            this.mScanFilters = data;
            this.mAdvSeen.clear();
            this.mScanCounts.clear();
            this.log(LogLevel.DEBUG, "start scan with filter: " + JSON.stringify(filterArray));
            if (filterArray.length == 0) {
              ble.startBLEScan(null, scanOption);
            } else {
              ble.startBLEScan(filterArray, scanOption);
            }
            console.log("startScan----------end")
          } catch (err) {
            this.log(LogLevel.ERROR, "start scan end  with error: " + JSON.stringify(err));
          }
          result.success(true)
          break;
        }
        case "setLogLevel": {

          let idx: number = call.args as number;
          this.logLevel = LogLevel[idx] as ESObject;
          this.log(LogLevel.DEBUG, "setLogLevel: " + this.logLevel );
          this.mIsScanning = true;
          result.success(true);
          break;
        }
        case "stopScan": {
          ble.stopBLEScan();
          ble.off('BLEDeviceFind', (data) => {
            this.scanCallback(data);
          })
          this.mIsScanning = false
          result.success(true);
          break;
        }
        case "connect": {
          // console.log("connect--------" + JSON.stringify(call.args))
          this.log(LogLevel.DEBUG, "connect with args: " + JSON.stringify(call.args));
          let args: Map<string, string | boolean> = call.args;
          let remoteId: string = args.get("remote_id") as string;
          this.remoteId = remoteId;
          let autoConnect: boolean = args.get("auto_connect") as boolean;
          let permissions = new Array<Permissions>();
          // permissions.push("ohos.permission.ACCESS_BLUETOOTH");
          // await this.ensurePermissions(permissions, result);
          if (this.isAdapterOn() == false) {
            result.error("connect", "bluetooth must be turned on", null);
            return;
          }
          if (this.mCurrentlyConnectingDevices.get(this.remoteId) != null) {
            hilog.debug(0, "already connected", null)
            result.success(true); // still work to do
            return;
          }
          if (this.mConnectedDevices.get(this.remoteId) != null) {
            hilog.debug(0, "already connected", null)
            result.success(false); // still work to do
            return;
          }
          this.waitIfBonding();
          try {
            this.clientDevice = ble.createGattClientDevice(this.remoteId);
            this.clientDevice.connect()

            this.clientDevice.on('BLEConnectionStateChange', this.ConnectStateChanged);
          } catch (err) {
            console.error('errCode: ' + (err as BusinessError).code + ', errMessage: ' +
            (err as BusinessError).message);
          }
          if (this.clientDevice != null) {
            this.mCurrentlyConnectingDevices.set(remoteId, this.clientDevice);
          } else {
            result.error("startScan", "getBluetoothLeScanner() is null. Is the Adapter on?", null);
            return;
          }
          if (autoConnect) {
            this.mAutoConnected.set(remoteId, this.clientDevice);
          } else {
            this.mAutoConnected.delete(remoteId);
          }
          result.success(true);
          break;
        }
        case "readRssi": {
          let remoteId: string = call.args;
          // check connection
          let gatt: ble.GattClientDevice | undefined = this.mConnectedDevices.get(remoteId);
          if (gatt == null || gatt == undefined) {
            result.error("readRssi", "device is disconnected", null);
            break;
          }
          // wait if any device is bonding (increases reliability)
          this.waitIfBonding();
          let readRssiFlag = true;
          let rssiValue: number = 0;
          let errcode: number = 0;
          let errMsg: string = "GATT_SUCCESS";
          try {
            rssiValue = await gatt.getRssiValue();
          } catch (e) {
            readRssiFlag = false
          }
          // read rssi
          if (rssiValue == 0 || rssiValue == null || rssiValue == undefined) {
            result.error("readRssi", "gatt.readRemoteRssi() returned false", null);
            break;
          }
          result.success(true);
          let response: Map<String, Object> = new Map();
          response.set("remote_id", remoteId);
          response.set("rssi", rssiValue);
          response.set("success", readRssiFlag ? 1 : 0);
          response.set("error_code", errcode);
          response.set("error_string", errMsg);
          this.channel?.invokeMethod("OnReadRssi", response);
          break;
        }
        case "discoverServices": {
          let remoteId: string = call.args;

          // check connection
          let gatt: ble.GattClientDevice | undefined = this.mConnectedDevices.get(remoteId);
          if (gatt == null) {
            result.error("discoverServices", "device is disconnected", null);
            break;
          }

          // wait if any device is bonding (increases reliability)
          this.waitIfBonding();

          // discover services
          let services: Array<ble.GattService> = await gatt.getServices();
          if (services == null || services.length == 0) {
            result.error("discoverServices", "gatt.discoverServices() returned false", null);
            break;
          }
          this.OnDiscoveredServices(services, remoteId)
          result.success(true);
          break;
        }
        case "setNotifyValue": {
          let data: Map<string, string | boolean> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let secondaryServiceUuid: string = data.get("secondary_service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let forceIndications: string = data.get("force_indications") as string;
          let enable: boolean = data.get("enable") as boolean;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            result.error("setNotifyValue", "device is disconnected", null);
            break;
          }
          this.waitIfBonding();
          let gattServices = await gatt.getServices();
          if (gattServices == null || gattServices == undefined) {
            result.error("setNotifyValue", "no service ", null);
          }
          let found =
            await this.locateCharacteristic(serviceUuid, secondaryServiceUuid, characteristicUuid, gattServices);
          if (found?.error != null) {
            result.error("setNotifyValue", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found?.characteristic as ble.BLECharacteristic;
          try {
            await gatt.setCharacteristicChangeNotification(characteristic,characteristic.properties?.notify);
            if(characteristic.properties?.notify){
              try {
                gatt.on('BLECharacteristicChange', (characteristicChangeReq: ble.BLECharacteristic) => {
                  this.onCharacteristicReceived(remoteId, gattServices, characteristicChangeReq);
                });
              } catch (err) {
                let errMessage = 'errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message;
                // console.error('===onBLECharacteristicChange===' + errMessage);
                this.log(LogLevel.ERROR, "onBLECharacteristicChange with error: " + JSON.stringify(err));
                result.error("onBLECharacteristicChange", errMessage, null);
              }
            }else {
              try {
                gatt.off('BLECharacteristicChange');
              } catch (err) {
                let errMessage = 'errCode: ' + (err as BusinessError).code + ', errMessage: ' + (err as BusinessError).message;
                // console.error('===offBLECharacteristicChange===' + errMessage);
                this.log(LogLevel.ERROR, "offBLECharacteristicChange with error: " + JSON.stringify(err));
                result.error("offBLECharacteristicChange", errMessage, null);
              }
            }
          } catch (e) {
            console.log(e)
          }
          let descriptor: ble.BLEDescriptor | null =
            this.getDescriptorFromArray(CCCD, characteristic.descriptors);
          if (descriptor == null) {
            let uuid: string = this.uuidStr(characteristic.serviceUuid);
            result.success(false);
            return;
          }
          let descriptorValue: byte[] | null = null;
          if (enable) {
            let canNotify: boolean = characteristic.properties?.notify as boolean
            let canIndicate: boolean = characteristic.properties?.indicate as boolean
            if (!canIndicate && !canNotify) {
              result.error("setNotifyValue",
                "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic", null);
              break;
            }
            if (forceIndications && !canIndicate) {
              result.error("setNotifyValue", "INDICATE not supported by this BLE characteristic", null);
              break;
            }
            if (canIndicate) {
              descriptorValue = this.ENABLE_INDICATION_VALUE;
            }
            if (canNotify) {
              descriptorValue = this.ENABLE_NOTIFICATION_VALUE;
            }
            if (forceIndications) {
              descriptorValue = this.ENABLE_INDICATION_VALUE;
            }
          } else {
            descriptorValue = this.DISABLE_NOTIFICATION_VALUE;
          }
          let key: string = remoteId + ":" + serviceUuid + ":" + characteristicUuid + ":" + CCCD;
          this.mWriteDesc.set(key, this.bytesToHex(descriptorValue as number[]));
          if (descriptorValue) {
            let u8Array: Uint8Array = new Uint8Array(descriptorValue)
            descriptor.descriptorValue = this.typedArrayToBuffer(u8Array)
          }
          gatt.writeDescriptorValue(descriptor).then((writeDescriptor) => {
            console.info('writeDescriptorValue promise success');
            let pair: ServicePair = this.readAndWriteServicePair(gattServices, characteristic);
            let response: Map<string, Object> = new Map<string, Object>();
            response.set("remote_id", remoteId);
            response.set("service_uuid", this.uuidStr(descriptor?.serviceUuid as string));
            if (pair.secondary != null) {
              response.set("secondary_service_uuid", this.uuidStr(pair.secondary));
            }
            response.set("characteristic_uuid", descriptor?.characteristicUuid as string);
            response.set("descriptor_uuid", descriptor?.descriptorUuid as string);
            let buffer = descriptor?.descriptorValue;
            let unie8: Uint8Array = new Uint8Array(buffer as ArrayBuffer)
            response.set("value", HexUtil.formatHexString(unie8));
            response.set("success", 1);
            response.set("error_code", 0);
            response.set("error_string", "GATT_SUCCESS");
            this.channel?.invokeMethod("OnDescriptorWritten", response);
            result.success(true);
          }).catch((e: BusinessError) => {
            result.error("setNotifyValue", "gatt.writeDescriptor() returned false", null);
          });
          break;
        }
        case "disconnect": {
          try {
            let remoteId: string = call.args;
            let gatt: ble.GattClientDevice | null = null;
            if (gatt == null) {
              gatt = this.mCurrentlyConnectingDevices.get(remoteId) as ble.GattClientDevice;
              if (gatt != null) {
                this.log(LogLevel.DEBUG, "disconnect: cancelling connection in progress");
              }
            }
            if (gatt == null) {
              gatt = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
            }
            if (gatt == null) {
              gatt = this.mAutoConnected.get(remoteId) as ble.GattClientDevice;
              if (gatt != null) {
                this.log(LogLevel.DEBUG, "already disconnected. disabling autoconnect");
                this.mAutoConnected.delete(remoteId);
                gatt.disconnect();
                gatt.close();
                result.success(false); // no work to do
                return;
              }
            }
            if (gatt == null) {
              this.log(LogLevel.DEBUG, "already disconnected");
              result.success(false); // no work to do
              return;
            }
            this.mAutoConnected.delete(remoteId);

            if (this.mCurrentlyConnectingDevices.get(remoteId) != null) {
              console.log("connection canceled---- start ")
              this.mCurrentlyConnectingDevices.delete(remoteId);
              gatt.close();
              let bmUserCanceledErrorCode: number = 23789258;
              let response: Map<string, string | number> = new Map<string, string>();
              response.set("remote_id", remoteId);
              response.set("connection_state",
                this.bmConnectionStateEnum(constant.ProfileConnectionState.STATE_DISCONNECTED))
              response.set("disconnect_reason_code", bmUserCanceledErrorCode);
              response.set("disconnect_reason_string", "connection canceled");
              console.log("connection canceled---- end ")
              this.channel?.invokeMethod("OnConnectionStateChanged", response);
            } else {
              gatt.disconnect();
            }
            result.success(true);
            break;
          } catch (e) {
            console.error("")
          }

        }
        case "requestMtu": {
          let data: Map<string, string | number> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let mtu: number = data.get("mtu") as number;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          this.log(LogLevel.DEBUG, 'requestMtu:' + mtu);
          if (gatt == null) {
            result.error("requestMtu", "gatt.requestMtu() returned false", null);
            break;
          }
          this.waitIfBonding();
          let mtuFlag: boolean = true;
          let errCode: number = 0;
          let errMsg: string = "GATT_SUCCESS";
          try {
            gatt.setBLEMtuSize(mtu);
          } catch (e) {
            errCode = e.code;
            errMsg = e.message;
            mtuFlag = false;
          }
          if (!mtuFlag) {
            result.error("requestMtu", "gatt.requestMtu() returned false", null);
            break;
          }
          this.mMtu.set(remoteId, mtu);
          let response: Map<string, object | string | number> = new Map<string, object>();
          response.set("remote_id", remoteId);
          response.set("mtu", mtu);
          response.set("success", mtuFlag ? 1 : 0);
          response.set("error_code", errCode);
          response.set("error_string", errMsg);
          this.channel?.invokeMethod("OnMtuChanged", response);
          result.success(true);
          break;
        }
        case "readCharacteristic": {
          let data: Map<string, string> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let secondaryServiceUuid: string = data.get("secondary_service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;

          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          let services: ble.GattService[] = await gatt.getServices();
          if (gatt == null) {
            result.error("readCharacteristic", "device is disconnected", null);
            break;
          }
          this.waitIfBonding();
          let found = await this.locateCharacteristic(serviceUuid, secondaryServiceUuid, characteristicUuid, services);
          if (found?.error != null) {
            result.error("readCharacteristic", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found?.characteristic as ble.BLECharacteristic;
          if (!characteristic.properties?.read) {
            result.error("readCharacteristic",
              "The READ property is not supported by this BLE characteristic", null);
            break;
          }
          let readCharacteristic: ble.BLECharacteristic | null = null;
          try {

            readCharacteristic = await gatt.readCharacteristicValue(characteristic);
          } catch (e) {
            result.error("readCharacteristic",
              "gatt.readCharacteristic() returned false", null);
            break;
          }

          this.onCharacteristicReceived(remoteId, services, readCharacteristic as ble.BLECharacteristic)
          gatt.on('BLECharacteristicChange', (characteristicChangeReq: ble.BLECharacteristic) => {
            this.onCharacteristicReceived(remoteId, services, characteristicChangeReq);
          });
          result.success(true);
          break;


        }
        case "writeCharacteristic": {
          let data: Map<string, string | number> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let secondaryServiceUuid: string = data.get("secondary_service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let value: string = data.get("value") as string;
          let writeTypeInt: number = data.get("write_type") as number;
          let allowLongWrite: boolean = data.get("allow_long_write") as number != 0;
          // WRITE	1	表示写入特征值，需要对端设备的回复。
          // WRITE_NO_RESPONSE	2	表示写入特征值，不需要对端设备的回复。
          let writeType: number = writeTypeInt == 0 ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            result.error("writeCharacteristic", "device is disconnected", null);
            break;
          }
          let gattServices: ble.GattService[] = await gatt.getServices();
          this.waitIfBonding();
          let found: ChrFound =
            await this.locateCharacteristic(serviceUuid, secondaryServiceUuid, characteristicUuid,
              gattServices) as ChrFound;
          if (found?.error != null) {
            result.error("writeCharacteristic", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic | null = found.characteristic;
          ble.GattWriteType.WRITE
          ble.GattWriteType.WRITE_NO_RESPONSE
          if (writeType == ble.GattWriteType.WRITE) {
            if (!characteristic?.properties?.write) {
              result.error("writeCharacteristic",
                "The WRITE property is not supported by this BLE characteristic", null);
              break;
            }
          } else {
            if (!characteristic?.properties?.writeNoResponse) {
              result.error("writeCharacteristic",
                "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic", null);
              break;
            }
          }
          let maxLen: number = this.getMaxPayload(remoteId, writeType, allowLongWrite);
          let dataLen: number = HexUtil.hexStringToBytes(value)?.byteLength as number;

          if (dataLen > maxLen) {
            let a: string = writeTypeInt == 0 ? "withResponse" : "withoutResponse";
            let b: string = writeTypeInt == 0 ? (allowLongWrite ? ", allowLongWrite" : ", noLongWrite") : "";
            let str: string =
              "data longer than allowed. dataLen: " + dataLen + " > max: " + maxLen + " (" + a + b + ")";
            result.error("writeCharacteristic", str, null);
            break;
          }

          let key: string = remoteId + ":" + serviceUuid + ":" + characteristicUuid;
          this.mWriteChr.set(key, value);
          let writeFlag: boolean = false;
          let writeValue: ArrayBuffer = this.typedArrayToBuffer(HexUtil.hexStringToBytes(value) as Uint8Array);
          characteristic.characteristicValue = writeValue;
          let errorMessage: string = ""
          let errorCode: string = ""
          try {
            this.log(LogLevel.DEBUG, `特征${characteristicUuid}即将写入数据: 0x${value.toUpperCase()}`);
            await gatt.writeCharacteristicValue(characteristic, writeType);
            this.log(LogLevel.DEBUG, `数据写入成功`);
          } catch (e) {
            errorMessage = e.message;
            errorCode = e.code.toString()
            writeFlag = true;
          }
          if (writeFlag) {
            this.log(LogLevel.DEBUG, `数据写入失败 ErrorCode: ${errorCode}}, ErrorMessage: ${errorMessage}}`);
            result.error("writeCharacteristic", `errorcde: ${errorCode} ,  errmessage: ${errorMessage}`, null);
            break;
          }
          let key1: string = remoteId + ":" + serviceUuid + ":" + characteristicUuid;
          let value1: string | undefined = this.mWriteChr.get(key) != null ? this.mWriteChr.get(key) : "";
          this.mWriteChr.delete(key);
          let response: Map<string, Object> = new Map<string, Object>();
          response.set("remote_id", remoteId);
          response.set("service_uuid", serviceUuid);
          if (secondaryServiceUuid != null) {
            response.set("secondary_service_uuid", secondaryServiceUuid);
          }
          response.set("characteristic_uuid", characteristicUuid);
          response.set("value", value);
          response.set("success", writeFlag ? 0 : 1);
          response.set("error_code", 0);
          response.set("error_string", "")
          this.channel?.invokeMethod("OnCharacteristicWritten", response);
          result.success(true);
          break;
        }
        case "readDescriptor": {
          let data: Map<string, string> = call.args;
          let remoteId: string = data.get("remote_id") as string;
          let serviceUuid: string = data.get("service_uuid") as string;
          let secondaryServiceUuid: string = data.get("secondary_service_uuid") as string;
          let characteristicUuid: string = data.get("characteristic_uuid") as string;
          let descriptorUuid: string = data.get("descriptor_uuid") as string;

          // check connection
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          this.waitIfBonding();
          if (gatt == null) {
            result.error("readDescriptor", "device is disconnected", null);
            break;
          }
          let services: ble.GattService[] = await gatt.getServices();
          let found: ChrFound = await this.locateCharacteristic(serviceUuid, secondaryServiceUuid, characteristicUuid,
            services) as ChrFound;

          if (found.error != null) {
            result.error("readDescriptor", found.error, null);
            break;
          }

          let characteristic: ble.BLECharacteristic = found.characteristic as ble.BLECharacteristic;
          let descriptor: ble.BLEDescriptor =
            this.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors) as ble.BLEDescriptor;
          if (descriptor == null) {
            let s: string =
              "descriptor not found on characteristic. (desc: " + descriptorUuid + " chr: " + characteristicUuid + ")";
            result.error("writeDescriptor", s, null);
            break;
          }
          let service: ble.GattService | null = null;
          services.forEach(item => {
            if (this.uuidStr(item.serviceUuid) == serviceUuid) {
              service = item
            }
          })
          let errorMessage: string = ""
          let errorCode: number = 0;
          let readDescriptor: ble.BLEDescriptor | null = null;
          let readDescriptorFlag: boolean = false;
          try {
            readDescriptor = await gatt.readDescriptorValue(descriptor);
          } catch (e) {
            errorMessage = e.message;
            errorCode = e.code;
            readDescriptorFlag = true;
            result.error("readDescriptor", "gatt.readDescriptor() returned false", null);
            break;
          }

          let response: Map<string, string | number> = new Map<string, string>();
          if (service) {
            let pair: ServicePair = this.descriptorReadServicePair(service, services);
            response.set("remote_id", remoteId);
            if (pair.primary) {
              response.set("service_uuid", this.uuidStr(pair.primary));
            }
            if (pair.secondary != null) {
              response.set("secondary_service_uuid", this.uuidStr(pair.secondary));
            }
          }
          response.set("characteristic_uuid", this.uuidStr(readDescriptor.characteristicUuid));
          response.set("descriptor_uuid", this.uuidStr(readDescriptor.descriptorUuid));
          response.set("value", HexUtil.formatHexString(new Uint8Array(readDescriptor.descriptorValue)));
          response.set("success", readDescriptorFlag ? 0 : 1);
          response.set("error_code", errorCode);
          response.set("error_string", errorMessage);
          this.channel?.invokeMethod("OnDescriptorRead", response);
          result.success(true);
          break;
        }
        case "writeDescriptor": {
          let data: Map<string, object | string> = call.args;
          let remoteId = data.get("remote_id") as string;
          let serviceUuid = data.get("service_uuid") as string;
          let secondaryServiceUuid = data.get("secondary_service_uuid") as string;
          let characteristicUuid = data.get("characteristic_uuid") as string;
          let descriptorUuid = data.get("descriptor_uuid") as string;
          let value = data.get("value") as string;

          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            result.error("writeDescriptor", "device is disconnected", null);
            break;
          }
          let gattService: Array<ble.GattService> = await gatt.getServices();
          this.waitIfBonding();
          let found: ChrFound = await this.locateCharacteristic(serviceUuid, secondaryServiceUuid, characteristicUuid,
            gattService) as ChrFound;
          if (found.error != null) {
            result.error("writeDescriptor", found.error, null);
            break;
          }
          if (found.error != null) {
            result.error("writeDescriptor", found.error, null);
            break;
          }
          let characteristic: ble.BLECharacteristic = found.characteristic as ble.BLECharacteristic;
          let descriptor: ble.BLEDescriptor =
            this.getReadDescriptorFromArray(descriptorUuid, characteristic.descriptors) as ble.BLEDescriptor;
          if (descriptor == null) {
            let s: string =
              "descriptor not found on characteristic. (desc: " + descriptorUuid + " chr: " + characteristicUuid + ")";
            result.error("writeDescriptor", s, null);
            break;
          }
          let mtu: number = this.mMtu.get(remoteId) as number;
          let valueBytes: number = HexUtil.hexStringToBytes(value)?.byteLength as number;
          if ((mtu - 3) < valueBytes) {
            let s: string = "data longer than mtu allows. dataLength"
            result.error("writeDescriptor", s, null);
            break;
          }

          // let key: string = remoteId + ":" + serviceUuid + ":" + characteristicUuid + ":" + descriptorUuid;
          // this.mWriteDesc.set(key, value);

          let writeValue: ArrayBuffer = this.typedArrayToBuffer(HexUtil.hexStringToBytes(value) as Uint8Array);
          descriptor.descriptorValue = writeValue;
          let errorCode: number = 0;
          let errorMessage: string = ""
          let writeDescriptorFlags: boolean = true
          try {
            gatt.writeDescriptorValue(descriptor)
          } catch (e) {
            writeDescriptorFlags = false
            errorCode = e.code;
            errorMessage = e.message;
            result.error("setNotifyValue", "gatt.writeDescriptor() returned false", null);
            break;
          }
          let pair: ServicePair = this.readAndWriteServicePair(gattService, characteristic);

          let respServiceUuid: string = this.uuidStr(pair.primary as string);

          let respSecondaryServiceUuid: string | null = pair.secondary != null ? this.uuidStr(pair.secondary) : null;
          let respCharacteristicUuid: string = this.uuidStr(characteristicUuid) as string;
          let respDescriptorUuid: string = this.uuidStr(descriptorUuid);
          let response: Map<string, object | string | number> = new Map();
          response.set("remote_id", remoteId);
          response.set("service_uuid", respServiceUuid);
          if (respSecondaryServiceUuid != null) {
            response.set("secondary_service_uuid", respSecondaryServiceUuid);
          }
          response.set("characteristic_uuid", respCharacteristicUuid);
          response.set("descriptor_uuid", respDescriptorUuid);
          response.set("value", value);
          response.set("success", writeDescriptorFlags ? 1 : 0);
          response.set("error_code", errorCode);
          response.set("error_string", errorMessage);
          this.channel?.invokeMethod("OnDescriptorWritten", response)
        }
        case "getBondedDevices": {
          let devices: Array<string> = connection.getPairedDevices();
          let deviceList: List<Map<string, object | string>> = new List();

          devices.forEach(async (device) => {
            let name: string = await ble.createGattClientDevice(device).getDeviceName();
            deviceList.add(this.bmBluetoothDevice(device, name));
          })
          let response: Map<string, object | string> = new Map<string, object | string>();
          response.set("devices", deviceList);
          result.success(response);
          break;
        }
        case "getBondState": {
          let remoteId: string = call.args;
          let res: connection.BondState = connection.getPairState(remoteId);
          let response: Map<string, string | number | null> = new Map();
          response.set("remote_id", remoteId);
          response.set("bond_state", this.bmBondStateEnum(res));
          response.set("prev_state", null);
          result.success(response);
          break;
        }
        case "createBond": {
          let remoteId: string = call.args;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            result.error("createBond", "device is disconnected", null);
            break;
          }
          let res: connection.BondState = connection.getPairState(remoteId);
          // already bonded?
          if (res == connection.BondState.BOND_STATE_BONDED) {
            result.success(false); // no work to do
            break;
          }
          // bonding already in progress?
          if (res == connection.BondState.BOND_STATE_BONDING) {
            result.success(true); // caller must wait for bond completion
            break;
          }
          let pairFlag: boolean = false;
          try {
            connection.pairDevice(remoteId)
          } catch (e) {
            result.error("createBond", "device.createBond() returned false", null);
            break;
          }
          result.success(true);
          break;
        }
        case "removeBond": {
          let remoteId: string = call.args;
          let res: connection.BondState = connection.getPairState(remoteId);
          // already bonded?
          if (res == connection.BondState.BOND_STATE_INVALID) {
            result.success(false); // no work to do
            break;
          }

          result.success(true);
          break;

        }
        case "clearGattCache": {
          let remoteId: string = call.args;
          let gatt: ble.GattClientDevice = this.mConnectedDevices.get(remoteId) as ble.GattClientDevice;
          if (gatt == null) {
            result.error("clearGattCache", "device is disconnected", null);
            break;
          }
          result.success(true);
          break;
        }
        default: {
          result.notImplemented()
          break;
        }
      }
    } catch (e) {
      let error: string = e.message
      return;
    }
  }

  bondStateChange() {

  }

  bmBondStateEnum(bs: number): number {
    switch (bs) {
      case connection.BondState.BOND_STATE_INVALID:
        return 0;
      case connection.BondState.BOND_STATE_BONDING:
        return 1;
      case connection.BondState.BOND_STATE_BONDED:
        return 2;
      default:
        return 0;
    }
  }

  descriptorReadServicePair(service: ble.GattService, services: ble.GattService[]): ServicePair {
    let result: ServicePair = new ServicePair();
    if (service.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }

    for (let i = 0; i < services.length; i++) {
      let includeService: ble.GattService[] = services[i].includeServices as ble.GattService[]
      for (let j = 0; j < includeService.length; j++) {
        if (includeService[j].serviceUuid == service.serviceUuid) {
          result.primary = services[i].serviceUuid;
          result.secondary = includeService[i].serviceUuid;
          return result
        }
      }
    }
    return result;
  }

  getMaxPayload(remoteId: string, writeType: number, allowLongWrite: boolean): number {
    // 512 this comes from the BLE spec. Characteritics should not
    // be longer than 512. Android also enforces this as the maximum in internal code.
    let maxAttrLen: number = 512;

    // if no response, we can only write up to MTU-3.
    // This is the same limitation as iOS, and ensures transfer reliability.
    if (writeType == ble.GattWriteType.WRITE_NO_RESPONSE || allowLongWrite == false) {
      let mtu: number = this.mMtu.get(remoteId) as number;
      if (mtu == null) {
        mtu = 23; // 23 is the minumum MTU, as per the BLE spec
      }
      return Math.min(mtu - 3, maxAttrLen);
    } else {
      return maxAttrLen;
    }
  }

  onCharacteristicReceived(address: string, services: ble.GattService[],
    characteristic: ble.BLECharacteristic,) {
    let pair: ServicePair = this.readAndWriteServicePair(services, characteristic);
    if (this.uuidStr(pair.primary as string) == "1800") {
      if (this.uuidStr(characteristic.characteristicUuid) == "2A05") {
        let response: Map<string, Object> = this.bmBluetoothDevice(address)
        this.channel?.invokeMethod("OnServicesReset", response);
      }
    }
    let response: Map<string, Object> = new Map<string, Object>();
    response.set("remote_id", address);
    response.set("service_uuid", this.uuidStr(pair.primary as string));
    if (pair.secondary != null) {
      response.set("secondary_service_uuid", this.uuidStr(pair.secondary));
    }
    response.set("characteristic_uuid", this.uuidStr(characteristic.characteristicUuid));
    response.set("value", HexUtil.formatHexString(new Uint8Array(characteristic.characteristicValue)));
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    this.log(LogLevel.DEBUG, "onCharacteristicReceived: 0x" + HexUtil.formatHexString(new Uint8Array(characteristic.characteristicValue)));
    this.channel?.invokeMethod("OnCharacteristicReceived", response)

  }


  readAndWriteServicePair(services: ble.GattService[], characteristic: ble.BLECharacteristic): ServicePair {
    let result: ServicePair = new ServicePair();
    let service: ble.GattService | null = null;
    for (let i = 0; i < services.length; i++) {
      if (services[i].serviceUuid === characteristic.serviceUuid) {
        service = services[i]
      }
    }
    if (service?.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }
    for (let i = 0; i < services.length; i++) {
      if (services[i].includeServices) {
        let secondService: ble.GattService[] = services[i].includeServices as ble.GattService[]
        for (let j = 0; j < secondService.length; j++) {
          if (secondService[i].serviceUuid === service?.serviceUuid) {
            result.primary = services[i].serviceUuid
            result.secondary = secondService[j].serviceUuid
          }
        }
      }
    }
    return result;
  }

  bytesToHex(bytes: byte[]) {
    if (bytes === null || bytes.length === 0) {
      return "";
    }
    let hexStr = '';
    for (let i = 0; i < bytes.length; i++) {
      let hex = bytes[i].toString(16);
      if (hex.length === 1) {
        hex = '0' + hex;
      }
      hexStr += hex;
    }
    return hexStr;
  }


  typedArrayToBuffer(array: Uint8Array): ArrayBuffer {
    return array.buffer.slice(array.byteOffset, array.byteLength + array.byteOffset)
  }

  getDescriptorFromArray(uuid: string, array: Array<ble.BLEDescriptor>): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(array[i].descriptorUuid) === this.uuid128(uuid)) {
        return array[i]
      }
    }
    return null;
  }

  getReadDescriptorFromArray(uuid: string, array: Array<ble.BLEDescriptor>): ble.BLEDescriptor | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(array[i].descriptorUuid) === this.uuid128(uuid)) {
        return array[i]
      }
    }
    return null;
  }

  async locateCharacteristic(serviceId: string, secondaryServiceId: string,
    characteristicId: string, gattServices: ble.GattService[]): Promise<ChrFound | undefined> {
    let primaryService = this.getServiceFromArray(serviceId, gattServices);
    if (primaryService == null) {
      let result: ChrFound = new ChrFound(null, "service not found '" + serviceId + "'");
      return result
    }
    let secondaryService: ble.GattService | null = null;
    if (secondaryServiceId != null && secondaryServiceId.length > 0) {
      if (primaryService.includeServices) {
        secondaryService = this.getServiceFromArray(serviceId, primaryService.includeServices);
      }
      if (secondaryService != null) {
        return new ChrFound(null, "secondaryService not found '" + secondaryServiceId + "'");
      }
    }
    let service: ble.GattService = (secondaryService != null) ? secondaryService : primaryService;
    let characteristic: ble.BLECharacteristic | null =
      this.getCharacteristicFromArray(characteristicId, service.characteristics);
    if (characteristic == null) {
      return new ChrFound(null, "characteristic not found in service " +
        "(chr: '" + characteristicId + "' svc: '" + serviceId + "')");
    }
    return new ChrFound(characteristic, null);
  }

  getServiceFromArray(uuid: string, array: Array<ble.GattService>): ble.GattService | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(uuid) === this.uuid128(array[i].serviceUuid)) {
        return array[i];
      }
    }
    return null;
  }

  getCharacteristicFromArray(uuid: string, array: Array<ble.BLECharacteristic>): ble.BLECharacteristic | null {
    for (let i = 0; i < array.length; i++) {
      if (this.uuid128(array[i].characteristicUuid) === this.uuid128(uuid)) {
        return array[i];
      }
    }
    return null;
  }

  uuid128(uuid: string): string {
    if (uuid.length === 4) {
      // 16-bit uuid
      return `0000${uuid}-0000-1000-8000-00805f9b34fb`.toLowerCase();
    } else if (uuid.length === 8) {
      // 32-bit uuid
      return `${uuid}-0000-1000-8000-00805f9b34fb`.toLowerCase();
    } else {
      // 128-bit uuid
      return uuid.toLowerCase();
    }
  }

  uuidStr(uuid: string): string {
    uuid = this.uuid128(uuid)
    let starts: boolean = uuid.startsWith("0000");
    let ends: boolean = uuid.endsWith("-0000-1000-8000-00805f9b34fb");
    if (starts && ends) {
      // 16-bit
      return uuid.substring(4, 8);
    } else if (ends) {
      // 32-bit
      return uuid.substring(0, 8);
    } else {
      // 128-bit
      return uuid;
    }
  }

  ConnectStateChanged = (state: ble.BLEConnectionChangeState) => {
    if (state.state != constant.ProfileConnectionState.STATE_CONNECTED &&
      state.state != constant.ProfileConnectionState.STATE_DISCONNECTED) {
      return;
    }
    if (state.state == constant.ProfileConnectionState.STATE_CONNECTED) {
      this.mConnectedDevices.set(state.deviceId as string, this.clientDevice as ble.GattClientDevice);
      this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
      this.mMtu.set(this.remoteId as string, 23)
    }

    if (state.state == constant.ProfileConnectionState.STATE_DISCONNECTED) {
      this.mConnectedDevices.delete(this.remoteId as string);
      this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
      this.mBondingDevices.delete(this.remoteId as string);
      if (!this.mAutoConnected.has(this.remoteId as string)) {
        if (this.clientDevice != null) {
          this.clientDevice.close();
        }
      }
    }
    let response: Map<string, string | number> = new Map();

    let connectState: number = this.bmConnectionStateEnum(state.state);
    response.set("remote_id", this.remoteId as string);
    response.set("connection_state", connectState);

    if (state.state != constant.ProfileConnectionState.STATE_CONNECTED) {
      response.set("disconnect_reason_code", 1)
      response.set("disconnect_reason_string", TextUtils.hciStatusString(1))
    }
    this.channel?.invokeMethod("OnConnectionStateChanged", response);
  }

  async waitIfBonding() {
    let counter: number = 0;
    if (this.mBondingDevices.size != 0 && this.mBondingDevices != null) {
      if (counter == 0) {
        hilog.debug(0, "waiting for bonding to complete", null);
        await this.delay(50);
        counter++;
      }
    }
    if (counter > 0) {
      hilog.debug(0, "bonding completed", null);
    }
  }

  delay(milliseconds: number) {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, milliseconds);
    });
  }

  bmConnectionStateEnum(cs: number): number {
    switch (cs) {
      case constant.ProfileConnectionState.STATE_DISCONNECTED:
        return 0;
      case constant.ProfileConnectionState.STATE_CONNECTED:
        return 1;
      default:
        return 0;
    }
  }

  bmBluetoothDevice(deviceAddress: string, name?: string): Map<string, string> {
    let map: Map<string, string> = new Map();
    map.set("remote_id", deviceAddress)
    if (name) {
      map.set("platform_name", name);
    }
    return map;
  }

  async ensurePermissions(permissions: Permissions[], result: MethodResult) {
    console.log("ensurePermissions----------start")
    let permissionsNeeded = new Array<Permissions>();
    for (const permission of permissions) {
      let flag = await this.checkSelfPermission(permission);
      if (permission != null && flag) {
        permissionsNeeded.push(permission);
      }
    }
    if (permissionsNeeded.length == 0 || permissionsNeeded == null) {
      result.success(true);
      return;
    }
    if (this.abilityPluginBinding != null) {
      const c: UIAbility = this.abilityPluginBinding.getAbility();
      let context = c.context;
      let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // requestPermissionsFromUser会判断权限的授权状态来决定是否唤起弹窗
      atManager.requestPermissionsFromUser(context, permissionsNeeded).then((data) => {
        let grantStatus: Array<number> = data.authResults;
        let length: number = grantStatus.length;
        for (let i = 0; i < length; i++) {
          if (grantStatus[i] === 0) {
            console.log("----- 权限获取成功")
            let accessNum: number = -1;
            accessNum = access.getState();
            let map: Map<string, number> = new Map();
            map.set("adapter_state", this.bmAdapterStateEnum(accessNum))
            result.success(map);
          } else {
            // 用户拒绝授权，提示用户必须授权才能访问当前页面的功能，并引导用户到系统设置中打开相应的权限
            result.error("turn", "FlutterBluePlus requires ohos Permission ohos.permission.ACCESS_BLUETOOTH", null);
          }
        }
        // 授权成功
      }).catch((err: BusinessError) => {
        console.error(`Failed to request permissions from user. Code is ${err.code}, message is ${err.message}`);
      })
    }
    console.log("ensurePermissions----------end")
  }

  async checkSelfPermission(permission: Permissions): Promise<boolean> {
    let tokenId: number = 0;
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let bundleInfo: bundleManager.BundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
    tokenId = appInfo.accessTokenId;
    grantStatus = await atManager.checkAccessToken(tokenId, permission);
    return grantStatus == -1;
  }

  OnDiscoveredServices(gattServices: Array<ble.GattService>, remoteId: string) {
    let services: List<object> = new List<object>();

    gattServices.forEach((service) => {
      services.add(this.bmBluetoothService(service, remoteId, gattServices));
    })

    let response: Map<string, object | string | number> = new Map();
    response.set("success", 1);
    response.set("error_code", 0);
    response.set("error_string", "GATT_SUCCESS");
    response.set("remote_id", remoteId as string);
    response.set("services", services);
    this.channel?.invokeMethod("OnDiscoveredServices", response);
  }

  bmBluetoothService(service: ble.GattService, remoteId: string,
    gattServices?: Array<ble.GattService>): Map<string, object | string | number> {
    let characteristics: List<object> = new List<object>();
    service.characteristics.forEach((characteristic) => {
      characteristics.add(this.bmBluetoothCharacteristic(remoteId, characteristic, service, gattServices));
    })
    let includedServices: List<object> = new List<object>();
    try {
      if (service.includeServices) {
        for (let i = 0; i < service.includeServices?.length; i++) {
          if (service.serviceUuid === service.includeServices[i].serviceUuid) {
            continue; // skip, infinite recursion
          }
          includedServices.add(this.bmBluetoothService(service.includeServices[i], remoteId));
        }
      }
    } catch (e) {
      console.error("error: " + JSON.stringify(e))
    }

    let map: Map<string, object | string | number> = new Map();
    map.set("remote_id", remoteId);
    map.set("service_uuid", this.uuidStr(service.serviceUuid));
    map.set("is_primary", service.isPrimary ? 1 : 0);
    map.set("characteristics", characteristics);
    map.set("included_services", includedServices);
    return map;
  }

  bmBluetoothCharacteristic(remoteId: string, characteristic: ble.BLECharacteristic, service: ble.GattService,
    gattServices?: Array<ble.GattService>): Map<string, object | string> {
    let pair: ServicePair = this.getServicePair(service, gattServices);
    let descriptors: List<object> = new List<object>();
    characteristic.descriptors?.forEach((d) => {
      descriptors.add(this.bmBluetoothDescriptor(remoteId, d));
    })
    let map: Map<string, object | string> = new Map<string, object | string>();
    map.set("remote_id", remoteId);
    if (pair.primary != null) {
      map.set("service_uuid", this.uuidStr(pair.primary));
    }
    if (pair.secondary != null) {
      map.set("secondary_service_uuid", this.uuidStr(pair.secondary));
    }
    map.set("characteristic_uuid", this.uuidStr(characteristic.characteristicUuid));
    map.set("descriptors", descriptors);
    map.set("properties", this.bmCharacteristicProperties(characteristic));
    return map
  }

  bmCharacteristicProperties(characteristic: ble.BLECharacteristic): Map<string, Object> {
    let props: Map<string, object | number> = new Map<string, object | number>();
    if (characteristic.properties) {
      characteristic.properties.write ? props.set("write", 1) : props.set("write", 0);
      characteristic.properties.writeNoResponse ? props.set("write_without_response", 1) :
      props.set("write_without_response", 0);
      characteristic.properties.read ? props.set("read", 1) : props.set("read", 0);
      characteristic.properties.notify ? props.set("notify", 1) : props.set("notify", 0);
      characteristic.properties.indicate ? props.set("indicate", 1) : props.set("indicate", 0);
      props.set("broadcast", 0);
      props.set("authenticated_signed_writes", 0);
      props.set("extended_properties", 0);
      props.set("notify_encryption_required", 0);
      props.set("indicate_encryption_required", 0);
    }
    return props
  }

  getServicePair(service: ble.GattService,
    gattServices?: Array<ble.GattService>): ServicePair {
    let result: ServicePair = new ServicePair();
    if (service.isPrimary) {
      result.primary = service.serviceUuid;
      return result;
    }
    if (gattServices) {
      for (let i = 0; i < gattServices.length; i++) {
        let secondary: Array<ble.GattService> = gattServices[i].includeServices as Array<ble.GattService>;
        for (let j = 0; j < secondary.length; j++) {
          if (secondary[i].serviceUuid == service.serviceUuid) {
            result.primary = gattServices[i].serviceUuid;
            result.secondary = secondary[j].serviceUuid;
            return result;
          }
        }
      }
    }
    return result;
  }

  disconnectAllDevices(func: string) {
    this.mConnectedDevices.forEach((value, key) => {
      if (func == "adapterTurnOff") {
        let state: number = constant.ProfileConnectionState.STATE_DISCONNECTED;
        if (state != constant.ProfileConnectionState.STATE_DISCONNECTED &&
          state != constant.ProfileConnectionState.STATE_CONNECTED) {
          return;
        }
        if (state == constant.ProfileConnectionState.STATE_DISCONNECTED) {
          this.mConnectedDevices.delete(this.remoteId as string);
          this.mCurrentlyConnectingDevices.delete(this.remoteId as string);
          this.mBondingDevices.delete(this.remoteId as string);
          if (!this.mAutoConnected.has(key)) {
            value.close();
          }
        }
        let response: Map<string, string | number> = new Map();
        let connectState: number = this.bmConnectionStateEnum(state);
        response.set("remote_id", this.remoteId as string);
        response.set("connection_state", connectState);
        response.set("disconnect_reason_code", 0);
        response.set("disconnect_reason", TextUtils.hciStatusString(0))
        this.channel?.invokeMethod("OnConnectionStateChanged", response);
      } else {
        value.disconnect();
        value.close();
      }
      this.mConnectedDevices.clear();
      this.mCurrentlyConnectingDevices.clear();
      this.mBondingDevices.clear();
      this.mMtu.clear();
      this.mWriteChr.clear();
      this.mWriteDesc.clear();
      this.mAutoConnected.clear();
    })
  }


  bmBluetoothDescriptor(remote_id: string, descriptor: ble.BLEDescriptor): Map<string, object | string> {
    let map: Map<string, object | string> = new Map<string, object | string>();
    map.set("remote_id", remote_id);
    map.set("descriptor_uuid", this.uuidStr(descriptor.descriptorUuid));
    map.set("characteristic_uuid", this.uuidStr(descriptor.characteristicUuid));
    map.set("service_uuid", this.uuidStr(descriptor.serviceUuid));
    return map;
  }

  async scanCallback(data: Array<ble.ScanResult>) {
    let item = data[0]
    let device: BleDevice =
      new BleDevice(item.deviceId, "", item.rssi, new Uint8Array(item.data), new Date().getTime(),
        item.connectable);
    let gattClient = ble.createGattClientDevice(device.getMac());
    let deviceName: string = await gattClient.getDeviceName();
    device.setName(deviceName);
    let remoteId: string = device.getMac();

    let scanRecord: Uint8Array = device.getScanRecord();

    let advHex: string = HexUtil.formatHexString(scanRecord);

    if (this.mScanFilters.get("continuous_updates") as boolean == false) {
      let isDuplicate: boolean = this.mAdvSeen.has(remoteId) && this.mAdvSeen.get(remoteId) === advHex;
      this.mAdvSeen.set(remoteId, advHex);
      if (isDuplicate) {
        return;
      }
    }
    let name: string = device.getName() != null ? device.getName() : "";
    let keywords: List<string> = this.mScanFilters.get("with_keywords") as List<string>;
    if (this.filterKeywords(keywords, name) == false) {
      return;
    }
    if (this.mScanFilters.get("continuous_updates") as boolean != false) {
      let count: number = this.scanCountIncrement(remoteId);
      let divisor: number = this.mScanFilters.get("continuous_divisor") as number;
      if ((count % divisor) != 0) {
        return;
      }
    }
    let response: Map<string, Object> = new Map<string, Object>();
    let deviceList: List<Map<string, Object>> = new List<Map<string, Object>>();
    let map: Map<string, Object> = new Map();
    if (device.getName() != null) {
      map.set("platform_name", device.getName());
    } else {
      map.set("platform_name", "");
    }
    if (device.getMac() != null) {
      map.set("remote_id", device.getMac());
    }
    if (device.getConnectable()) {
      map.set("connectable", 1);
    }
    if (device.getRssi() != 0) {
      map.set("rssi", device.getRssi());
    }
    if (device.getManufactureData()) {
      map.set("manufacturer_data", device.getManufactureData());
    }
    if(device.getTxPowerLevel() != 0){
      map.set("tx_power_level", device.getTxPowerLevel());
    }
    if(device.getServiceUuids().length > 0){
      map.set("service_uuids", device.getServiceUuids());
    }
    deviceList.add(map)
    response.set("advertisements", deviceList);
    if (this.channel != null) {
      this.channel.invokeMethod("OnScanResponse", response);
    }
  }

  bmAdapterStateEnum(as: number): number {
    switch (as) {
      case access.BluetoothState.STATE_OFF:
        return 6;
      case access.BluetoothState.STATE_ON:
        return 4;
      case access.BluetoothState.STATE_TURNING_OFF:
        return 5;
      case access.BluetoothState.STATE_TURNING_ON:
        return 3;
      default:
        return 0;

    }
  }

  isAdapterOn(): boolean {
    try {
      return access.getState() == access.BluetoothState.STATE_ON;
    } catch (e) {
      return false;
    }
  }

  onReceiveEvent(data: access.BluetoothState) {
    let map: Map<string, object | number> = new Map();
    map.set("adapter_state", this.bmAdapterStateEnum(data));
    this.channel?.invokeMethod("OnAdapterStateChanged", map);
    if (data == access.BluetoothState.STATE_BLE_TURNING_OFF ||
      data == access.BluetoothState.STATE_OFF) {
      this.disconnectAllDevices("adapterTurnOff");
    }
  }

  scanCountIncrement(remoteId: string) {
    if (this.mScanCounts.get(remoteId) == null) {
      this.mScanCounts.set(remoteId, 0);
    }
    let count: number = this.mScanCounts.get(remoteId) as number;
    this.mScanCounts.set(remoteId, count + 1);
    return count;
  }

  filterKeywords(keywords: List<string>, target: string): boolean {
    if (keywords.length == 0 || keywords == null) {
      return true;
    }
    if (target == null) {
      return false;
    }
    for (let i = 0; i < keywords.length; i++) {
      if (target.includes(keywords[i])) {
        return true;
      }
    }
    return false;
  }
}

class ChrFound {
  public characteristic: ble.BLECharacteristic | null = null;
  public error: string | null = null;

  constructor(characteristic: ble.BLECharacteristic | null, error: string | null) {
    this.characteristic = characteristic;
    this.error = error;
  }
}


class ServicePair {
  primary: string | null = null;
  secondary: string | null = null;
}

// 定义日志级别的枚举
export enum LogLevel {
  NONE = 0,    // 不输出任何日志
  ERROR = 1,   // 错误级别日志
  WARN = 2,    // 警告级别日志
  INFO = 3,    // 信息级别日志
  DEBUG = 4,   // 调试级别日志
  VERBOSE = 5  // 冗余级别日志（可选）
}
