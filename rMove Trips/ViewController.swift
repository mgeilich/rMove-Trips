//
//  ViewController.swift
//  motion
//
//  Created by Michael Geilich on 3/16/20.
//  Copyright © 2020 RSG, Inc. All rights reserved.
//

/*
    rMove Trips uses location and motion to determine trip starts and stops.
    Motion events are processed and an activity is made 'active' when no events with
    other types of motion are received for minTime.  When an activity is made active, all others
    are made inactive, so only one activity is active at a time.
 
    When an activity remains active for more than minDistance, any trip in process is stopped.
    If the new motion is not 'stopped' then a new trip is also started.  So trips can stop/start
    based on a mode change, with the only dwell being the new mode's minTime.
 */

import UIKit
import Foundation
import CoreMotion
import CoreLocation

// Keys for the activity[] array
struct ActivityType {
    let stopped:Int = 0
    let walking:Int = 1
    let running:Int = 2
    let cycling:Int = 3
    let vehicle:Int = 4
    let unknown:Int = 5
}
let activityType = ActivityType()

struct Activity {
    let name:        String
    var active:      Bool           // Whether this is the active mode or not.  Only one at a time.
    let minTime:     Double         // Minimum seconds for this mode to be considered Active.
    var startTime:   Double         // When this activity was first recognized.
    let minDistance: Double         // Minimum meters for this mode to be considered Active.
    var startLocation: CLLocation   // Where this activity was first recognized.
}

class ViewController: UIViewController, CLLocationManagerDelegate {

    let locationManager: CLLocationManager = CLLocationManager()
    let motionActivityManager = CMMotionActivityManager()
    var confidence = CMMotionActivityConfidence.low
    
    var log = UITextView()     // Running commentary in scrollable views
    var debug = UITextView()

    // This is the guts of the behavior, parameters for each activity.
    var activity: [Activity] = [
        Activity(name: "Stopped", active: false, minTime: 30.0, startTime: 0, minDistance: 0,    startLocation: CLLocation()),
        Activity(name: "Walking", active: false, minTime: 30.0, startTime: 0, minDistance: 30.0, startLocation: CLLocation()),
        Activity(name: "Running", active: false, minTime: 60.0, startTime: 0, minDistance: 30.0, startLocation: CLLocation()),
        Activity(name: "Cycling", active: false, minTime: 60.0, startTime: 0, minDistance: 50.0, startLocation: CLLocation()),
        Activity(name: "Vehicle", active: false, minTime: 60.0, startTime: 0, minDistance: 50.0, startLocation: CLLocation()),
        Activity(name: "Unknown", active: false, minTime: 60.0, startTime: 0, minDistance: 100.0,startLocation: CLLocation())
    ]
    
    var smallGeofence = CLCircularRegion(center: CLLocationCoordinate2D(), radius: 30.0, identifier: "smallGeofence")

    // A little state information.
    var tripInProgress: Bool = false
    var currentLocation = CLLocation()
    var lastActivityUpdate = Date()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Resize the log view when the device is rotated and prevent the display from sleeping while app is in the foreground.
        NotificationCenter.default.addObserver(self, selector: #selector(wasRotated), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIApplication.shared.isIdleTimerDisabled = true
        
        // Two output views and no need for storyboard, sweet.
        setupLogs()
        
        // Set up the geofences
        smallGeofence.notifyOnEntry = false
        smallGeofence.notifyOnExit = true
        
        // Set the location parameters
        locationManager.requestAlwaysAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .otherNavigation           // Don't let coordinates snap to nearest road
        locationManager.allowsBackgroundLocationUpdates  = true
        locationManager.showsBackgroundLocationIndicator  = false
        locationManager.distanceFilter = kCLDistanceFilterNone   //Meters
        locationManager.delegate = self
        
        // Start monitoring and handle callbacks.
        startGeofencing()
        startWatchingMotion()
    }
    
    // Called each time iOS gives us an activity update.
    var color: UIColor = UIColor.clear      // Log text is colored according to motion.confidence
    func startWatchingMotion() {
        if CMMotionActivityManager.isActivityAvailable() {
            motionActivityManager.startActivityUpdates(to: OperationQueue.main) { (motion) in
                self.processMotion(motion!)
            }
        }
    }
    
    // Called on a geofence exit.  Only the last motion in the queue is correct for this location.
    func checkMotionQueue() {
        motionActivityManager.queryActivityStarting(from: lastActivityUpdate+1, to: Date(), to: OperationQueue.main)
        { (motions, error) in
            if let motion = motions?.last {
                self.processMotion(motion)
            }
        }
    }
    
    let confColor:[CMMotionActivityConfidence: UIColor] = [
        .low: .red, .medium: .yellow, .high: .green]
    
    func processMotion(_ motion: CMMotionActivity) {
        if motion.confidence == .low {
            return      // These just aren't very good and we have plenty without them
        }
        self.color = confColor[motion.confidence] ?? .white
                
        // The ordering of these needs to match the activity[] array
        for (index, element) in [
                (motion.stationary),
                (motion.walking),
                (motion.running),
                (motion.cycling),
                (motion.automotive),
                (motion.unknown)
            ].enumerated() {
                    
            if element {
                let currentTime = motion.startDate
                
                // Log all transitions to the debug pane.
                self.writeDebugWithDate(date: currentTime,
                                        entry: self.activity[index].name,
                                        color: self.color)
                                
                // Go through the activity[] array and find the activity that matches this motion.
                for index2 in 0..<self.activity.count {
                    if (index == index2) {
                        // Only set the startTime once, we can get the same activity multiple times in a row.
                        if self.activity[index].startTime == 0 {
                            self.activity[index].startTime = currentTime.timeIntervalSince1970
                            self.activity[index].startLocation = self.currentLocation
                        }
                    } else {
                        // Forget about any prior different activity
                        self.activity[index2].startTime = 0
                    }
                }
                lastActivityUpdate = currentTime
            }
        
            // Check to see if this activity has been on long enough to make it Active
            self.checkForNewActive(index)
                
            // Check to see if the user has moved far enough with an active activity to end and start a trip.
            self.checkForNewTrip()
        }
    }
    

    
    // Checks to see if an activity has been detected long enough.  If so, turns off other activities and make this one the active one.
    func checkForNewActive(_ index: Int) {
        let startTime = self.activity[index].startTime
        let minTime = self.activity[index].minTime
        
        if startTime > 0 &&
            lastActivityUpdate.timeIntervalSince1970 - startTime > minTime &&
            self.activity[index].active == false {

            for index2 in 0..<self.activity.count {
                if index == index2 {
                    self.activity[index].active = true
                    writeLogWithDate(date: Date(timeIntervalSince1970: self.activity[index].startTime),
                                     entry: self.activity[index].name,
                                     color: self.color)
                    if tripInProgress {
                        writeLog("\nTrip Ended", color: .white)
                        tripInProgress = false
                    }
                    startGeofencing()
                } else {
                    self.activity[index2].startTime = 0
                    self.activity[index2].active = false
                }
            }
        }
    }
    
    // Checks to see if a new trip has started or ended and if so, logs the result
    func checkForNewTrip() {
        for index in 0..<self.activity.count {
            // If we're going from any motion to stopped then we had a trip going.
            if index == activityType.stopped  &&
                        self.activity[index].active {
                if tripInProgress {
                    writeLogWithDate(date: Date(timeIntervalSince1970:self.activity[index].startTime),
                                     entry: "\nTrip Ended - shouldn't get here?", color: .white)
                    startGeofencing()
                }
            } else {
                if !tripInProgress &&
                    self.activity[index].active &&
                    self.activity[index].startLocation.distance(from: currentLocation)  >
                    self.activity[index].minDistance + currentLocation.horizontalAccuracy {
                        tripInProgress = true
                        writeLogWithDate(date: Date(timeIntervalSince1970:self.activity[index].startTime),
                                     entry: "\nTrip Started", color: .white)
                }
            }
        }
    }
    
    var isGeofencing:Bool = false
    func startGeofencing() {
        if isGeofencing {
            return
        }
        locationManager.stopUpdatingLocation()
        let smallGeofence = CLCircularRegion(center: locationManager.location!.coordinate, radius: 30.0, identifier: "smallGeofence")
        locationManager.startMonitoring(for: smallGeofence)
        writeLog("\nstart geofence", color:.white)
        isGeofencing = true
    }
    
    func stopGeofencing() {
        
        if !isGeofencing {
            return
        }
        locationManager.stopMonitoring(for: smallGeofence)
        locationManager.startUpdatingLocation()
        writeLog("\nstop geofence", color:.white)
        isGeofencing = false
    }
    
    /* --------------------------------------------------------------------------------------------------- */
    // Formatted print routines.
    
    func writeLog(_ entry: String, color: UIColor) {
        let colored = NSMutableAttributedString()
        colored.append(self.log.attributedText)
        let attributes = [NSAttributedString.Key.foregroundColor: color]
        colored.append(NSAttributedString(string: entry, attributes: attributes))
        self.log.attributedText = colored
        
        let logFile = "logfile.txt"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(logFile)
            do {
                try self.log.text.write(to: fileURL, atomically: false, encoding: .utf8)
            }
            catch {
                print("Couldn't write to logfile")
            }
        }
    }
    
    func writeDebug(_ entry: String, color: UIColor) {
        // Need to append to what's already there to not overwrite colors.
        let colored = NSMutableAttributedString()
        colored.append(self.debug.attributedText)
        
        let attributes = [NSAttributedString.Key.foregroundColor: color]
        colored.append(NSAttributedString(string: entry, attributes: attributes))
        self.debug.attributedText = colored
        
        let debugFile = "debugfile.txt"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = dir.appendingPathComponent(debugFile)
            do {
                try self.debug.text.write(to: fileURL, atomically: false, encoding: .utf8)
            }
            catch {
                print("Couldn't write to debugfile")
            }
        }
    }
    
    func writeLogWithDate(date: Date, entry: String, color: UIColor) {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = .current
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "hh:mm:ss"
        let entry = "\n\(dateFormatter.string(from: date)): \(entry)"
        writeLog(entry, color: color)
    }
    
    func writeDebugWithDate(date: Date, entry: String, color: UIColor) {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = .current
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "hh:mm:ss"
        let entry = "\n\(dateFormatter.string(from: date)): \(entry)"
        writeDebug(entry, color: color)
    }
    
    /* --------------------------------------------------------------------------------------------------- */
    // Utility routines
    
    // Called when device rotation is detected.
    @objc func wasRotated() {
        log.frame = CGRect(x:5, y:20, width: self.view.frame.width/2 - 5, height: self.view.frame.height-30)
        debug.frame = CGRect(x:5+self.view.frame.width/2, y:20, width: self.view.frame.width/2 - 10, height: self.view.frame.height-30)
    }
    
    // View configuration
    func setupLogs() {
        log.isScrollEnabled = true
        log.isUserInteractionEnabled = true
        log.isEditable = false
        log.frame = CGRect(x:5, y:20, width: self.view.frame.width/2 - 5, height: self.view.frame.height-40)
        log.text = ""
        log.backgroundColor = .black
        self.view.addSubview(log)
        
        debug.isScrollEnabled = true
        debug.isUserInteractionEnabled = true
        debug.isEditable = false
        debug.frame = CGRect(x:5+self.view.frame.width/2, y:20, width: self.view.frame.width/2 - 10, height: self.view.frame.height-30)
        debug.text = ""
        debug.backgroundColor = .black
        self.view.addSubview(debug)
    }
    
    // Location Manager delegates
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        if let location = locations.last {
            currentLocation = location
        }
        // May have moved enough distance without a new motion to call it a trip start.
        self.checkForNewTrip()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status != .authorizedAlways {
            print("Not able to do background location")
        }
    }
    
    // called when user Enters a monitored region
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        writeLog("Entering region - this should never happen", color: .white)
    }
    
    // called when user Exits a monitored region
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if region is CLCircularRegion {
            self.checkMotionQueue()
            stopGeofencing()
        }
    }

    func locationManager(_ manager: CLLocationManager,
             didFailWithError error: Error)
    {
       print("Location fail")
    }

}


