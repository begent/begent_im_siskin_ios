//
// Chat.swift
//
// Siskin IM
// Copyright (C) 2021 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import TigaseSwift
import TigaseSwiftOMEMO
import UIKit
import Combine
import Shared
import Intents

public class Chat: ConversationBaseWithOptions<ChatOptions>, ChatProtocol, Conversation {
        
    public override var defaultMessageType: StanzaType {
        return .chat;
    }
    
    var localChatState: ChatState = .active;
    @Published
    private(set) var remoteChatState: ChatState? = nil;
    
    public var automaticallyFetchPreviews: Bool {
        return DBRosterStore.instance.item(for: account, jid: JID(jid)) != nil;
    }
    
    private var cancellables: Set<AnyCancellable> = [];
    
    public var debugDescription: String {
        return "Chat(account: \(account), jid: \(jid))";
    }

    init(context: Context, jid: BareJID, id: Int, lastActivity: LastConversationActivity, unread: Int, options: ChatOptions) {
        let contact = ContactManager.instance.contact(for: .init(account: context.userBareJid, jid: jid, type: .buddy));
        super.init(context: context, jid: jid, id: id, lastActivity: lastActivity, unread: unread, options: options, displayableId: contact);
        (context.module(.httpFileUpload) as! HttpFileUploadModule).isAvailablePublisher.combineLatest(context.$state, { isAvailable, state -> [ConversationFeature] in
            if case .connected(_) = state {
                return isAvailable ? [.httpFileUpload, .omemo] : [.omemo];
            } else {
                return [.omemo];
            }
        }).sink(receiveValue: { [weak self] value in
            self?.update(features: value);
        }).store(in: &cancellables);
    }
    
    public func isLocalParticipant(jid: JID) -> Bool {
        return account == jid.bareJid;
    }
    
    func changeChatState(state: ChatState) -> Message? {
        guard localChatState != state else {
            return nil;
        }
        self.localChatState = state;
        if (remoteChatState != nil) {
            let msg = Message();
            msg.to = JID(jid);
            msg.type = StanzaType.chat;
            msg.chatState = state;
            return msg;
        }
        return nil;
    }
    
    private var remoteChatStateTimer: Foundation.Timer?;
    
//    func updateDisplayName(rosterItem: RosterItem?) {
//        DispatchQueue.main.async {
//            self.displayName = rosterItem?.name ?? self.jid.stringValue;
//        }
//    }
    
    func update(remoteChatState state: ChatState?) {
        // proper handle when we have the same state!!
        let prevState = remoteChatState;
        if prevState == .composing {
            remoteChatStateTimer?.invalidate();
            remoteChatStateTimer = nil;
        }
        self.remoteChatState = state;
        
        if state == .composing {
            DispatchQueue.main.async {
                self.remoteChatStateTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { [weak self] timer in
                guard let that = self else {
                    return;
                }
                if that.remoteChatState == .composing {
                    that.remoteChatState = .active;
                    that.remoteChatStateTimer = nil;
                }
            });
            }
        }
    }
    
    public override func createMessage(text: String, id: String, type: StanzaType) -> Message {
        let msg = super.createMessage(text: text, id: id, type: type);
        msg.chatState = .active;
        msg.isMarkable = true;
        msg.messageDelivery = .request;
        self.localChatState = .active;
        return msg;
    }
    
    public func canSendChatMarker() -> Bool {
        return true;
    }
    
    public func sendChatMarker(_ marker: Message.ChatMarkers, andDeliveryReceipt receipt: Bool) {
        guard Settings.confirmMessages && options.confirmMessages else {
            return;
        }
        
        let message = self.createMessage();
        message.chatMarkers = marker;
        if receipt {
            message.messageDelivery = .received(id: marker.id)
        }
        message.hints = [.store];
        Task {
            try await self.send(message: message);
        }
    }
 
    public func prepareAttachment(url originalURL: URL) throws -> SharePreparedAttachment {
        let encryption = self.options.encryption ?? .none;
        switch encryption {
        case .none:
            return .init(url: originalURL, isTemporary: false, prepareShareURL: nil);
        case .omemo:
            let (encryptedData, hash) = try OMEMOModule.encryptFile(url: originalURL);
            let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);
            try encryptedData.write(to: tmpFile);
            return .init(url: tmpFile, isTemporary: true, prepareShareURL: { url in
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)!;
                parts.scheme = "aesgcm";
                parts.fragment = hash;
                let shareUrl = parts.url!;

                return shareUrl;
            });
        }
    }
    
    public func sendMessage(text: String, correctedMessageOriginId: String?) async throws {
        let stanzaId = UUID().uuidString;
        let encryption = self.options.encryption ?? Settings.messageEncryption;
        
        if let correctedMessageId = correctedMessageOriginId {
            DBChatHistoryStore.instance.correctMessage(for: self, stanzaId: correctedMessageId, sender: .none, data: text, correctionStanzaId: stanzaId, correctionTimestamp: Date(), newState: .outgoing(.unsent));
        } else {
            var messageEncryption: ConversationEntryEncryption = .none;
            switch encryption {
            case .omemo:
                messageEncryption = .decrypted(fingerprint: DBOMEMOStore.instance.identityFingerprint(forAccount: self.account, andAddress: SignalAddress(name: self.account.description, deviceId: Int32(bitPattern: DBOMEMOStore.instance.localRegistrationId(forAccount: self.account)!))));
            case .none:
                break;
            }
            let options = ConversationEntry.Options(recipient: .none, encryption: messageEncryption, isMarkable: true)
            _ = DBChatHistoryStore.instance.appendItem(for: self, state: .outgoing(.unsent), sender: .me(conversation: self), type: .message, timestamp: Date(), stanzaId: stanzaId, serverMsgId: nil, remoteMsgId: nil, data: text, appendix: nil, options: options, linkPreviewAction: .none);
        }
        
        try await resendMessage(content: text, isAttachment: false, encryption: encryption, stanzaId: stanzaId, correctedMessageOriginId: correctedMessageOriginId);
    }
    
    // we are only encrypting URL and not file content, it should be encoded prior uploading
    public func sendAttachment(url: String, appendix: ChatAttachmentAppendix, originalUrl: URL?) async throws {
        let stanzaId = UUID().uuidString;
        let encryption = self.options.encryption ?? Settings.messageEncryption;

        var messageEncryption: ConversationEntryEncryption = .none;
        switch encryption {
        case .omemo:
            messageEncryption = .decrypted(fingerprint: DBOMEMOStore.instance.identityFingerprint(forAccount: self.account, andAddress: SignalAddress(name: self.account.description, deviceId: Int32(bitPattern: DBOMEMOStore.instance.localRegistrationId(forAccount: self.account)!))));
        case .none:
            break;
        }
        let options = ConversationEntry.Options(recipient: .none, encryption: messageEncryption, isMarkable: true)
        if let msgId = DBChatHistoryStore.instance.appendItem(for: self, state: .outgoing(.unsent), sender: .me(conversation: self), type: .attachment, timestamp: Date(), stanzaId: stanzaId, serverMsgId: nil, remoteMsgId: nil, data: url, appendix: appendix, options: options, linkPreviewAction: .none) {
            if let url = originalUrl {
                _ = DownloadStore.instance.store(url, filename:  appendix.filename ?? url.lastPathComponent, with: "\(msgId)");
            }
        }
        try await resendMessage(content: url, isAttachment: true, encryption: encryption, stanzaId: stanzaId, correctedMessageOriginId: nil);
    }
    
    func resendMessage(content: String, isAttachment: Bool, encryption: ChatEncryption, stanzaId: String, correctedMessageOriginId: String?) async throws {
        let message = createMessage(text: content, id: stanzaId);
        if isAttachment {
            message.oob = content
        }
        message.lastMessageCorrectionId = correctedMessageOriginId;
        
        if #available(iOS 15.0, *) {
            let sender = INPerson(personHandle: INPersonHandle(value: account.description, type: .unknown), nameComponents: nil, displayName: AccountManager.getAccount(for: self.account)?.nickname, image: AvatarManager.instance.avatar(for: self.account, on: self.account)?.inImage(), contactIdentifier: nil, customIdentifier: account.description, isMe: true, suggestionType: .instantMessageAddress);
            let recipient = INPerson(personHandle: INPersonHandle(value: jid.description, type: .unknown), nameComponents: nil, displayName: self.displayName, image: AvatarManager.instance.avatar(for: self.jid, on: self.account)?.inImage(), contactIdentifier: nil, customIdentifier: jid.description, isMe: false, suggestionType: .instantMessageAddress);
            let intent = INSendMessageIntent(recipients: [recipient], outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: nil, conversationIdentifier: "account=\(account.description)|sender=\(jid.description)", serviceName: "Siskin IM", sender: sender, attachments: nil);
            let interaction = INInteraction(intent: intent, response: nil);
            interaction.direction = .outgoing;
            try await interaction.donate();
        }
        
        do {
            try await send(message: message, encryption: encryption);
            DBChatHistoryStore.instance.updateItemState(for: self, stanzaId: correctedMessageOriginId ?? message.id!, from: .outgoing(.unsent), to: .outgoing(.sent), withTimestamp: correctedMessageOriginId != nil ? nil : Date());
        } catch let error as XMPPError {
            guard error.condition == .gone else {
                DBChatHistoryStore.instance.markOutgoingAsError(for: self, stanzaId: message.id!, error: error)
                throw error;
            }
        }
    }
    
    private func send(message: Message, encryption: ChatEncryption) async throws {
        try await XmppService.instance.tasksQueue.schedule(for: jid, operation: {
            switch encryption {
            case .none:
                try await super.send(message: message);
            case .omemo:
                guard let context = self.context as? XMPPClient, context.isConnected else {
                    throw XMPPError(condition: .gone);
                }

                let encryptedMessage = try await context.module(.omemo).encrypt(message: message);
                try await super.send(message: encryptedMessage.message);
            }
        })
//
//            .schedule(for: jid, task: { callback in
//            switch encryption {
//            case .none:
//                super.send(message: message, completionHandler: { result in
//                    completionHandler(result);
//                    callback();
//                });
//            case .omemo:
//                guard let context = self.context as? XMPPClient, context.isConnected else {
//                    completionHandler(.failure(XMPPError(condition: .gone)));
//                    callback();
//                    return;
//                }
//                message.oob = nil;
//                context.module(.omemo).encode(message: message, completionHandler: { result in
//                    switch result {
//                    case .success(let encodedMessage):
//                        guard context.isConnected else {
//                            completionHandler(.failure(XMPPError(condition: .gone)))
//                            callback();
//                            return;
//                        }
//                        super.send(message: encodedMessage.message, completionHandler: { result in
//                            completionHandler(result);
//                            callback();
//                        });
//                    case .failure(let error):
//                        var errorMessage = NSLocalizedString("It was not possible to send encrypted message due to encryption error", comment: "message encryption failure");
//                        switch error {
//                        case SignalError.noSession:
//                            errorMessage = NSLocalizedString("There is no trusted device to send message to", comment: "message encryption failure");
//                        default:
//                            break;
//                        }
//                        completionHandler(.failure(XMPPError(condition: .unexpected_request, message: errorMessage)));
//                        callback();
//                    }
//                })
//            }
//        })
    }

    public override func isLocal(sender: ConversationEntrySender) -> Bool {
        switch sender {
        case .me(_):
            return true;
        default:
            return false;
        }
    }
}

typealias ConversationOptionsProtocol = ChatOptionsProtocol

public struct ChatOptions: Codable, ConversationOptionsProtocol, Equatable {
    
    var encryption: ChatEncryption?;
    public var notifications: ConversationNotification = .always;
    public var confirmMessages: Bool = true;
    
    init() {}
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self);
        if let val = try container.decodeIfPresent(String.self, forKey: .encryption) {
            encryption = ChatEncryption(rawValue: val);
        }
        notifications = ConversationNotification(rawValue: try container.decodeIfPresent(String.self, forKey: .notifications) ?? "") ?? .always;
        confirmMessages = try container.decodeIfPresent(Bool.self, forKey: .confirmMessages) ?? true;
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self);
        if encryption != nil {
            try container.encode(encryption!.rawValue, forKey: .encryption);
        }
        if notifications != .always {
            try container.encode(notifications.rawValue, forKey: .notifications);
        }
        try container.encode(confirmMessages, forKey: .confirmMessages);
    }
    
    public func equals(_ options: ChatOptionsProtocol) -> Bool {
        guard let options = options as? ChatOptions else {
            return false;
        }
        return options == self;
    }
    
    enum CodingKeys: String, CodingKey {
        case encryption = "encrypt"
        case notifications = "notifications";
        case confirmMessages = "confirmMessages"
    }
}
