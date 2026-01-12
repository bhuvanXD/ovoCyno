//Batch for creating service account hierarchies in BULK

/*
// === 🏭 DATA FACTORY EXECUTION (SAFE MODE) ===
 
ServiceAccountDataFactory factoryBatch = new ServiceAccountDataFactory(50000);

// ⚠️ WARNING: Do NOT use a batch size > 5. 
// This class performs individual inserts per hierarchy (non-bulkified). 
// Larger batch sizes will hit SOQL/DML limits from Triggers/Flows.
Database.executeBatch(factoryBatch, 3);
System.debug('🚀 Batch Job Submitted');


*/

public class ServiceAccountDataFactory implements Database.Batchable<Integer>, Database.Stateful {
    
    private Integer totalHierarchiesToCreate;
    private Integer successfulCreations = 0;
    
    public ServiceAccountDataFactory(Integer count) {
        this.totalHierarchiesToCreate = count;
    }

    public Iterable<Integer> start(Database.BatchableContext bc) {
        List<Integer> scope = new List<Integer>();
        for (Integer i = 1; i <= totalHierarchiesToCreate; i++) { scope.add(i); }
        return scope;
    }

    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        // --- DATA MAPS (To hold parent IDs) ---
        Map<Integer, Account> accountMap = new Map<Integer, Account>();
        Map<Integer, Contact> contactMap = new Map<Integer, Contact>();
        Map<Integer, Service_Account__c> saMap = new Map<Integer, Service_Account__c>();
        Map<Integer, Case> mainCaseMap = new Map<Integer, Case>();
        
        // 1. ACCOUNTS
        for (Integer i : scope) {
            accountMap.put(i, new Account(Name = 'Bulk Account ' + System.currentTimeMillis() + '_' + i));
        }
        insert accountMap.values();

        // 2. CONTACTS
        for (Integer i : scope) {
            contactMap.put(i, new Contact(AccountId = accountMap.get(i).Id, LastName = 'Bulk Con ' + i, Email = 'test' + i + '@example.com'));
        }
        insert contactMap.values();

        // 3. SERVICE ACCOUNTS
        for (Integer i : scope) {
            saMap.put(i, new Service_Account__c(
                Name = 'SA_INTERNAL_MIGRATION_' + i,
                Service_Account_Id__c = 'ACC-100000' + i,
                Offset__c = '0', Billing_Information_Offset__c = '0', SSE_Migration_Status_Offset__c = '0'
            ));
        }
        insert saMap.values();
        successfulCreations += scope.size();

        // 4. MAIN CASES
        Id complaintRT = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Complaints_Unescalated').getRecordTypeId();
        for (Integer i : scope) {
            mainCaseMap.put(i, new Case(
                Service_Account__c = saMap.get(i).Id,
                RecordTypeId = complaintRT,
                Complaints_Severity__c = '2',
                Issue__c = 'Bulk Issue', Investigation__c = 'Bulk Inv', Resolution__c = 'Bulk Res', Outcome__c = 'Bulk Outcome',
                Origin = 'CSAT', Triage_Filter__c = 'PAYM', Category_Level_Two__c = 'Collections', Category_Level_Three__c = 'Payment Plans',
                Signposted__c = false, Subject = 'Bulk Generated Case ' + i
            ));
        }
        insert mainCaseMap.values();

        // --- CHILDREN LISTS ---
        List<Addon__c> addons = new List<Addon__c>();
        List<Communication__c> comms = new List<Communication__c>();
        List<Contact_Permission__c> perms = new List<Contact_Permission__c>();
        List<SSE_Migration_Flags__c> sseFlags = new List<SSE_Migration_Flags__c>();
        List<SSE_Migration_Reference__c> sseRefs = new List<SSE_Migration_Reference__c>();
        List<Gas_Card__c> saGasCards = new List<Gas_Card__c>();
        
        // Agent Hierarchy (SA Level)
        Map<Integer, Agent__c> saAgentMap = new Map<Integer, Agent__c>();

        for (Integer i : scope) {
            Id saId = saMap.get(i).Id;
            Id conId = contactMap.get(i).Id;

            addons.add(new Addon__c(Service_Account__c = saId));
            comms.add(new Communication__c(Service_Account__c = saId));
            perms.add(new Contact_Permission__c(Service_Account__c = saId, Account_Binding_Key__c = 'KEY-' + i + '-' + System.currentTimeMillis()));
            sseFlags.add(new SSE_Migration_Flags__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId));
            sseRefs.add(new SSE_Migration_Reference__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId));
            saGasCards.add(new Gas_Card__c(Service_Account__c = saId, Customer__c = conId, Address_Line_1__c = '123 Bulk St', Town_City__c = 'Test City', Postcode__c = 'BK1 9ZZ'));
            
            // Prepare Agent for Insert
            saAgentMap.put(i, new Agent__c(Service_Account__c = saId));
        }
        
        // INSERT STANDARD CHILDREN (No Try-Catch)
        insert addons;
        insert comms;
        insert perms;
        insert sseFlags;
        insert sseRefs;
        insert saGasCards;
        insert saAgentMap.values();

        // AGENT ACTIONS & EMAILS (SA Level)
        List<Agent_Action__c> agentActions = new List<Agent_Action__c>();
        List<EmailMessage> agentEmails = new List<EmailMessage>();
        
        for (Integer i : scope) {
            Id agentId = saAgentMap.get(i).Id;
            // Email for Agent
            agentEmails.add(new EmailMessage(RelatedToId = agentId, Subject = 'Agent Email', FromAddress='t@t.com', ToAddress='t@t.com'));
            // Action for Agent
            agentActions.add(new Agent_Action__c(Agent__c = agentId));
        }
        insert agentActions;
        
        // Email for Agent Action
        // Note: We need the Action IDs to link the email
        // Since we just inserted agentActions list, if we want to link emails to THEM, we need to map them back?
        // Actually the original code did: insert agentAction; insert new EmailMessage(RelatedToId = agentAction.Id...);
        // So yes, we need them.
        
        // Since 'agentActions' list is preserved in order, and 'scope' is ordered, 
        // agentActions[0] corresponds to scope[0].
        // Let's use that valid assumption for bulk lists.
        List<EmailMessage> actionEmails = new List<EmailMessage>();
        for (Integer k = 0; k < agentActions.size(); k++) {
            actionEmails.add(new EmailMessage(RelatedToId = agentActions[k].Id, Subject = 'Action Email', FromAddress='t@t.com', ToAddress='t@t.com'));
        }
        insert agentEmails;
        insert actionEmails;

        // FINANCIALS
        Map<Integer, Direct_Debit_Mandate__c> mandateMap = new Map<Integer, Direct_Debit_Mandate__c>();
        for (Integer i : scope) {
            mandateMap.put(i, new Direct_Debit_Mandate__c(Service_Account__c = saMap.get(i).Id, Mandate_ID__c = 'DD-' + i + '-' + System.currentTimeMillis()));
        }
        insert mandateMap.values();

        List<Direct_Debit_Subscription__c> subs = new List<Direct_Debit_Subscription__c>();
        for (Integer i : scope) {
            subs.add(new Direct_Debit_Subscription__c(Service_Account__c = saMap.get(i).Id, Direct_Debit_Mandate__c = mandateMap.get(i).Id, Subscription_ID__c = 'SUB-' + i));
        }
        insert subs;

        // SUPPLY POINTS
        Map<Integer, Supply_Point__c> spMap = new Map<Integer, Supply_Point__c>();
        for (Integer i : scope) {
            spMap.put(i, new Supply_Point__c(Name = 'Bulk SP ' + i));
        }
        insert spMap.values();

        List<Supply_Point_Ownership__c> spOwns = new List<Supply_Point_Ownership__c>();
        List<Dispute__c> disputes = new List<Dispute__c>();
        List<Gas_Card__c> spGasCards = new List<Gas_Card__c>();

        for (Integer i : scope) {
            Id spId = spMap.get(i).Id;
            Id saId = saMap.get(i).Id;

            spOwns.add(new Supply_Point_Ownership__c(Service_Account__c = saId, Supply_Point__c = spId));
            disputes.add(new Dispute__c(Supply_Point__c = spId, Dispute_Id__c = 'DIS-' + i));
            spGasCards.add(new Gas_Card__c(
                Service_Account__c = saId, 
                Meter_Point_Reference__c = spId, 
                Customer__c = contactMap.get(i).Id,
                Address_Line_1__c = '123 Bulk User St',
                Town_City__c = 'Supply City', 
                Postcode__c = 'SP1 1AA'
            ));
        }
        insert spOwns;
        insert disputes;
        insert spGasCards;

        // --- CASE RELATED ITEMS ---
        List<Agent__c> caseAgents = new List<Agent__c>();
        List<Case_Action__c> caseActions2 = new List<Case_Action__c>();
        List<Knowledge_Article_Tracking__c> kats = new List<Knowledge_Article_Tracking__c>();
        List<EmailMessage> caseEmails2 = new List<EmailMessage>();
        List<Case> childCases = new List<Case>();
        
        // Ombudsman Maps
        Map<Integer, Ombudsman_Case__c> ombMap = new Map<Integer, Ombudsman_Case__c>();

        for (Integer i : scope) {
            Id cId = mainCaseMap.get(i).Id;
            
            caseAgents.add(new Agent__c(Case__c = cId));
            
            // Case Actions
            caseActions2.add(new Case_Action__c(Case__c = cId, Action__c = 'Callback', Type__c = 'Agent'));
            caseActions2.add(new Case_Action__c(Case__c = cId, Internal_Case__c = cId, Action__c = 'Callback', Type__c = 'Customer'));

            kats.add(new Knowledge_Article_Tracking__c(Case__c = cId));
            caseEmails2.add(new EmailMessage(ParentId = cId, Subject = 'Case Email', FromAddress='t@t.com', ToAddress='t@t.com'));

            // Child Cases
            childCases.add(new Case(ParentId = cId, Subject = 'Child Case via ParentId ' + i));
            childCases.add(new Case(Originating_Case__c = cId, Subject = 'Child Case via Originating ' + i));
            
            // Prepare Ombudsman
             Integer randomNum = Math.round(Math.random() * 899999) + 100000;
             ombMap.put(i, new Ombudsman_Case__c(Case__c = cId, Name = 'AB' + randomNum + '-23'));
        }

        insert caseAgents;
        insert caseActions2;
        insert kats;
        insert caseEmails2;
        insert childCases;
        insert ombMap.values();

        // Ombudsman Resolutions
        List<Ombudsman_Resolution__c> resolutions = new List<Ombudsman_Resolution__c>();
        for (Integer i : scope) {
             resolutions.add(new Ombudsman_Resolution__c(
                    Ombudsman_Case__c = ombMap.get(i).Id, 
                    Resolution_Case__c = mainCaseMap.get(i).Id, 
                    Ombudsman_Remedy__c = 'abc'
                ));
        }
        insert resolutions;

        // FILES (Optimized)
        List<ContentVersion> validFiles = new List<ContentVersion>();
        for (Integer i : scope) {
             // Case File
             validFiles.add(prepareFile(mainCaseMap.get(i).Id, 'Case Evidence ' + i));
             // Ombudsman File (always exists in this logic)
             validFiles.add(prepareFile(ombMap.get(i).Id, 'Ombudsman Report ' + i));
        }
        insert validFiles;

    }

    public void finish(Database.BatchableContext bc) {
        System.debug('✅ BATCH COMPLETE. Total SAs Created: ' + successfulCreations);
    }

    // --- 📎 FILE HELPER ---
    private ContentVersion prepareFile(Id parentId, String title) {
        ContentVersion cv = new ContentVersion();
        cv.Title = title;
        cv.PathOnClient = title.replaceAll(' ', '_') + '.txt';
        cv.VersionData = Blob.valueOf('This is dummy content for ' + title);
        cv.IsMajorVersion = true;
        cv.FirstPublishLocationId = parentId; 
        return cv;
    }
}