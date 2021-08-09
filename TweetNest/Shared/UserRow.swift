//
//  UserRow.swift
//  UserRow
//
//  Created by Jaehong Kang on 2021/08/09.
//

import SwiftUI
import TweetNestKit

struct UserRow: View {
    let userID: String
    @FetchRequest private var userDatas: FetchedResults<UserData>

    var body: some View {
        if let latestUserData = userDatas.last, let user = latestUserData.user {
            NavigationLink {
                UserView(user: user)
            } label: {
                HStack(spacing: 8) {
                    ProfileImage(userData: latestUserData)
                        .frame(width: 24, height: 24)

                    HStack(spacing: 4) {
                        Text(verbatim: latestUserData.name ?? "#\(user.id)")
                            .lineLimit(1)

                        if let username = latestUserData.username {
                            Text(verbatim: "@\(username)")
                                .lineLimit(1)
                                .foregroundColor(Color.gray)
                                .layoutPriority(1)
                        }
                    }
                }
            }
            .accessibilityLabel(Text(verbatim: latestUserData.name ?? "#\(user.id)"))
        } else {
            Text("#\(Int64(userID)?.formatted() ?? userID)")
        }
    }

    init(userID: String) {
        self.userID = userID
        self._userDatas = FetchRequest(
            sortDescriptors: [SortDescriptor(\.creationDate, order: .forward)],
            predicate: NSPredicate(format: "user.id == %@", userID),
            animation: .default
        )
    }
}

//struct UserRow_Previews: PreviewProvider {
//    static var previews: some View {
//        UserRow()
//    }
//}