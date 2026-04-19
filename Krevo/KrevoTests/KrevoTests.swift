//
//  KrevoTests.swift
//  KrevoTests
//
//  Created by Jonas on 3/22/26.
//

import Testing
@testable import Krevo
import Foundation

struct KrevoTests {

    @MainActor
    @Test func uploadTaskResetForRetryClearsTransientState() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("retry-reset-test.bin")
        let data = Data(repeating: 0xAB, count: 4_096)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = try UploadTask(fileURL: url)
        let attemptID = task.beginUploadAttempt()
        task.activateUpload(uploadId: "upload-123", uploadKey: "key-123", totalChunks: 8, attemptID: attemptID)
        task.state = .failed("boom")
        task.progress = 0.72
        task.uploadedBytes = 2_048
        task.speed = 1_500_000
        task.estimatedTimeRemaining = 2
        task.startTime = Date()
        task.completedChunks = 3
        task.totalChunks = 8
        task.completionTime = Date()
        task.completedBytes = 2_048

        task.resetForRetry()

        #expect(task.progress == 0)
        #expect(task.uploadedBytes == 0)
        #expect(task.speed == 0)
        #expect(task.estimatedTimeRemaining == nil)
        #expect(task.startTime == nil)
        #expect(task.completedChunks == 0)
        #expect(task.totalChunks == 0)
        #expect(task.completionTime == nil)
        #expect(task.uploadId == nil)
        #expect(task.uploadKey == nil)
        #expect(task.completedBytes == 0)
        if case .pending = task.state {
            #expect(true)
        } else {
            Issue.record("Task should return to pending state after reset")
        }
    }

    @MainActor
    @Test func uploadTaskProgressTracksCompletedAndPartialBytes() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("progress-math-test.bin")
        let data = Data(repeating: 0xCD, count: 10_000)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = try UploadTask(fileURL: url)
        let attemptID = task.beginUploadAttempt()
        task.activateUpload(uploadId: "upload-456", uploadKey: "key-456", totalChunks: 3, attemptID: attemptID)
        task.markChunkCompleted(partNumber: 1, chunkSize: 4_000, attemptID: attemptID)
        task.applyProgress([2: 1_500], attemptID: attemptID)

        #expect(task.uploadedBytes == 5_500)
        #expect(task.progress == 0.55)

        task.applyProgress([2: 2_000], attemptID: attemptID)
        #expect(task.uploadedBytes == 6_000)

        task.markChunkCompleted(partNumber: 2, chunkSize: 3_000, attemptID: attemptID)
        #expect(task.uploadedBytes == 7_000)
        #expect(task.progress == 0.7)
    }

}
