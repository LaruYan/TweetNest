//
//  Session+CleansingData.swift
//  Session+CleansingData
//
//  Created by Jaehong Kang on 2021/08/29.
//

import Foundation
import CoreData

extension Session {
    public nonisolated func cleansingAllAccounts() async throws {
        let context = persistentContainer.newBackgroundContext()
        
        let accountObjectIDs: [NSManagedObjectID] = try await context.perform(schedule: .enqueued) {
            let fetchRequest = NSFetchRequest<NSManagedObjectID>(entityName: Account.entity().name!)
            fetchRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \Account.creationDate, ascending: false)
            ]
            fetchRequest.resultType = .managedObjectIDResultType

            return try context.fetch(fetchRequest)
        }
        
        for accountObjectID in accountObjectIDs {
            try await cleansingAccount(for: accountObjectID, context: context)
        }
        
        try await cleansingAllUsers(context: context)
    }
    
    public nonisolated func cleansingAccount(for accountObjectID: NSManagedObjectID) async throws {
        try await cleansingAccount(for: accountObjectID, context: persistentContainer.newBackgroundContext())
    }
    
    nonisolated func cleansingAccount(for accountObjectID: NSManagedObjectID, context: NSManagedObjectContext) async throws {
        let userObjectID: NSManagedObjectID? = await context.perform(schedule: .enqueued) {
            guard let account = context.object(with: accountObjectID) as? Account else {
                return nil
            }
            
            guard let user = account.user else {
                return nil
            }
            
            return user.objectID
        }
        
        guard let userObjectID = userObjectID else {
            return
        }
        
        try await cleansingUser(for: userObjectID, context: context)
    }
    
    nonisolated func cleansingAllUsers(context: NSManagedObjectContext) async throws {
        let userObjectIDs: [NSManagedObjectID] = try await context.perform(schedule: .enqueued) {
            let userFetchRequest = NSFetchRequest<NSManagedObjectID>(entityName: User.entity().name!)
            userFetchRequest.predicate = NSPredicate(format: "account == NULL")
            userFetchRequest.resultType = .managedObjectIDResultType
            userFetchRequest.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
            
            return try context.fetch(userFetchRequest)
        }
        
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for userObjectID in userObjectIDs {
                taskGroup.addTask {
                    try await self.cleansingUser(for: userObjectID, context: context)
                }
            }
            
            try await taskGroup.waitForAll()
        }
    }
    
    nonisolated func cleansingUser(for userObjectID: NSManagedObjectID, context: NSManagedObjectContext) async throws {
        try await context.perform(schedule: .enqueued) {
            guard let user = context.object(with: userObjectID) as? User else {
                return
            }
            
            let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
            userFetchRequest.predicate = NSCompoundPredicate(
                andPredicateWithSubpredicates: [
                    NSPredicate(format: "account == NULL"),
                    NSPredicate(format: "SELF != %@", user),
                    NSPredicate(format: "id == %@", user.id ?? ""),
                ]
            )
            userFetchRequest.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
            
            let duplicatedUsers = try context.fetch(userFetchRequest)
            
            for duplicatedUser in duplicatedUsers {
                user.creationDate = [user.creationDate, duplicatedUser.creationDate].lazy.compactMap({$0}).min()
                user.lastUpdateEndDate = [user.lastUpdateEndDate, duplicatedUser.lastUpdateEndDate].lazy.compactMap({$0}).max()
                user.lastUpdateStartDate = [user.lastUpdateStartDate, duplicatedUser.lastUpdateStartDate].lazy.compactMap({$0}).max()
                user.modificationDate = [user.modificationDate, duplicatedUser.modificationDate].lazy.compactMap({$0}).max()

                user.addToUserDetails(duplicatedUser.userDetails ?? [])
                
                context.delete(duplicatedUser)
                try context.save()
            }
            
            let userDetails = user.sortedUserDetails ?? []
            
            for userDetail in userDetails {
                guard
                    let previousUserIndex = userDetails.firstIndex(of: userDetail).flatMap({ $0 - 1 }),
                    userDetails.indices ~= previousUserIndex
                else {
                    continue
                }
                
                let previousUserDetail = userDetails[previousUserIndex]
                
                if previousUserDetail ~= userDetail {
                    context.delete(userDetail)
                    try context.save()
                }
            }
        }
    }
}
