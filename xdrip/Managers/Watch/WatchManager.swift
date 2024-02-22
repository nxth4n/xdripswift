//
//  WatchManager.swift
//  xdrip
//
//  Created by Paul Plant on 9/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation
import WatchConnectivity

public final class WatchManager: NSObject, ObservableObject {
    
    // MARK: - private properties
    
    private let session: WCSession
    
    /// BgReadingsAccessor instance
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// a coreDataManager
    private var coreDataManager: CoreDataManager
    
    private var watchState = WatchState()
    
    // MARK: - intializer
    
    init(coreDataManager: CoreDataManager, session: WCSession = .default) {
        
        // set coreDataManager and bgReadingsAccessor
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        self.session = session
        super.init()
        
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
        
        processWatchState()
        
    }

    private func processWatchState() {
        guard session.isReachable else { return }
        
        DispatchQueue.main.async {
            
            // get 2 last Readings, with a calculatedValue
            let lastReading = self.bgReadingsAccessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 0)
            
            // there should be at least one reading
            guard lastReading.count > 0 else {
                print("exiting updateWatch(), no recent BG readings returned")
                return
            }
            
            //let bgReadingDate = lastReading[0].timeStamp
            let slopeOrdinal: Int = lastReading[0].slopeOrdinal() //? "" : lastReading[0].slopeArrow()
            
            var deltaChangeInMgDl: Double?
            
            // add delta if needed
            if lastReading.count > 1 {
                
                deltaChangeInMgDl = lastReading[0].currentSlope(previousBgReading: lastReading[1]) * lastReading[0].timeStamp.timeIntervalSince(lastReading[1].timeStamp) * 1000;
            }
            
            
            // create two simple arrays to send to the live activiy. One with the bg values in mg/dL and another with the corresponding timestamps
            // this is needed due to the not being able to pass structs that are not codable/hashable
            let hoursOfBgReadingsToSend: Double = 12
            
            let bgReadings = self.bgReadingsAccessor.getLatestBgReadings(limit: nil, fromDate: Date().addingTimeInterval(-3600 * hoursOfBgReadingsToSend), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
            
            var bgReadingValues: [Double] = []
            var bgReadingDates: [Date] = []
            
            for bgReading in bgReadings {
                bgReadingValues.append(bgReading.calculatedValue)
                bgReadingDates.append(bgReading.timeStamp)
            }
            
            // now process the WatchState
            self.watchState.bgReadingValues = bgReadingValues
            self.watchState.bgReadingDates = bgReadingDates
            self.watchState.isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl
            self.watchState.slopeOrdinal = slopeOrdinal
            self.watchState.deltaChangeInMgDl = deltaChangeInMgDl
            self.watchState.urgentLowLimitInMgDl = UserDefaults.standard.urgentLowMarkValue
            self.watchState.lowLimitInMgDl = UserDefaults.standard.lowMarkValue
            self.watchState.highLimitInMgDl = UserDefaults.standard.highMarkValue
            self.watchState.urgentHighLimitInMgDl = UserDefaults.standard.urgentHighMarkValue
            
            // specific to the Watch state
            self.watchState.activeSensorDescription = UserDefaults.standard.activeSensorDescription
            
            if let sensorStartDate = UserDefaults.standard.activeSensorStartDate {
                self.watchState.sensorAgeInMinutes = Double(Calendar.current.dateComponents([.minute], from: sensorStartDate, to: Date()).minute!)
            }
            self.watchState.sensorMaxAgeInMinutes = (UserDefaults.standard.activeSensorMaxSensorAgeInDays ?? 0) * 24 * 60
            
            self.sendToWatch()
        }
    }
    
    
    private func sendToWatch() {
        guard let data = try? JSONEncoder().encode(watchState) else {
            print("Watch state JSON encoding error")
            return
        }
        
        print("Current watch state will be sent to Watch")
        
        session.sendMessageData(data, replyHandler: nil) { error in
            print("Cannot send data message to watch")
        }
    }
    
    
    // MARK: - Public functions
    
    func updateWatchApp() {
        processWatchState()
    }
}


// MARK: - conform to WCSessionDelegate protocol

extension WatchManager: WCSessionDelegate {
    public func sessionDidBecomeInactive(_: WCSession) {}

    public func sessionDidDeactivate(_: WCSession) {}
    
    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("WCSession is activated: \(activationState == .activated)")
    }
    
    // process any received messages from the watch app
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // uncomment the following for debug console use
        print("received message from Watch App: \(message)")
        
        // if the action: refreshBGData message is received, then force the app to send new data to the Watch App
        if let requestWatchStateUpdate = message["requestWatchStateUpdate"] as? Bool, requestWatchStateUpdate {
            DispatchQueue.main.async {
                self.processWatchState()
            }
        }
    }
    
    public func session(_: WCSession, didReceiveMessageData _: Data) {}

    public func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            DispatchQueue.main.async {
                self.processWatchState()
            }
        }
    }
}
