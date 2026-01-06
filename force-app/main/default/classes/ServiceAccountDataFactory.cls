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
        for (Integer i : scope) { createSingleHierarchy(i); }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('✅ BATCH COMPLETE. Total SAs Created: ' + successfulCreations);
    }

    private void createSingleHierarchy(Integer index) {
        Id saId;
        Id mainCaseId;
        Id contactId;
        
        // --- 1. PARENTS & SERVICE ACCOUNT ---
        try {
            Account parentAccount = new Account(Name = 'Bulk Account ' + System.currentTimeMillis() + '_' + index);
            insert parentAccount;

            Contact customerContact = new Contact(AccountId = parentAccount.Id, LastName = 'Bulk Con ' + index, Email = 'test' + index + '@example.com');
            insert customerContact;
            contactId = customerContact.Id;

            Service_Account__c sa = new Service_Account__c(
                Name = 'SA_INTERNAL_MIGRATION_' + index,
                Service_Account_Id__c = 'ACC-100000' + index,
                Offset__c = '0', Billing_Information_Offset__c = '0', SSE_Migration_Status_Offset__c = '0'
            );
            insert sa;
            saId = sa.Id;
            successfulCreations++;
        } catch (Exception e) {
            System.debug('🛑 BLOCK A FAILED: ' + e.getMessage());
            return; // Stop if SA fails
        }

        // --- 2. MAIN CASE ---
        try {
            Id complaintRT = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Complaints_Unescalated').getRecordTypeId();

            Case c = new Case(
                Service_Account__c = saId,
                RecordTypeId = complaintRT,
                Complaints_Severity__c = '2',
                Issue__c = 'Bulk Issue', Investigation__c = 'Bulk Inv', Resolution__c = 'Bulk Res', Outcome__c = 'Bulk Outcome',
                Origin = 'CSAT', Triage_Filter__c = 'PAYM', Category_Level_Two__c = 'Collections', Category_Level_Three__c = 'Payment Plans',
                Signposted__c = false, Subject = 'Bulk Generated Case ' + index
            );
            insert c;
            mainCaseId = c.Id;
            
            // 📎 ATTACH FILE TO CASE (Optimized Method)
            createFile(mainCaseId, 'Case Evidence ' + index);

        } catch (Exception e) {
            System.debug('🛑 BLOCK B FAILED (Case): ' + e.getMessage());
        }

        // --- 3. CHILDREN & RELATED RECORDS ---
        if (saId != null) {
            try {
                insert new List<SObject>{
                    new Addon__c(Service_Account__c = saId),
                    new Communication__c(Service_Account__c = saId),
                    new Contact_Permission__c(Service_Account__c = saId, Account_Binding_Key__c = 'KEY-' + index + '-' + System.currentTimeMillis()),
                    new SSE_Migration_Flags__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId),
                    new SSE_Migration_Reference__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId),
                    new Gas_Card__c(Service_Account__c = saId, Customer__c = contactId, Address_Line_1__c = '123 Bulk St', Town_City__c = 'Test City', Postcode__c = 'BK1 9ZZ')
                };
            } catch (Exception e) { System.debug('⚠️ SA Children Failed'); }
            
            try {
                Direct_Debit_Mandate__c ddm = new Direct_Debit_Mandate__c(Service_Account__c = saId, Mandate_ID__c = 'DD-' + index + '-' + System.currentTimeMillis());
                insert ddm;
                insert new Direct_Debit_Subscription__c(Service_Account__c = saId, Direct_Debit_Mandate__c = ddm.Id, Subscription_ID__c = 'SUB-' + index);
            } catch (Exception e) { System.debug('⚠️ Financials Failed'); }
            
            try {
                Supply_Point__c sp = new Supply_Point__c(Name = 'Bulk SP ' + index);
                insert sp;
                insert new Supply_Point_Ownership__c(Service_Account__c = saId, Supply_Point__c = sp.Id);
                insert new Dispute__c(Supply_Point__c = sp.Id, Dispute_Id__c = 'DIS-' + index);
                insert new Gas_Card__c(Service_Account__c = saId, Meter_Point_Reference__c = sp.Id, Town_City__c = 'Supply City', Postcode__c = 'SP1 1AA');
            } catch (Exception e) { System.debug('⚠️ Supply Points Failed'); }
            
             try {
                Agent__c saAgent = new Agent__c(Service_Account__c = saId);
                insert saAgent;
                insert new EmailMessage(RelatedToId = saAgent.Id, Subject = 'Agent Email', FromAddress='t@t.com', ToAddress='t@t.com');

                Agent_Action__c agentAction = new Agent_Action__c(Agent__c = saAgent.Id);
                insert agentAction;
                insert new EmailMessage(RelatedToId = agentAction.Id, Subject = 'Action Email', FromAddress='t@t.com', ToAddress='t@t.com');
            } catch (Exception e) { System.debug('⚠️ Agent Hierarchy Failed'); }
        }

        // --- 4. CASE ITEMS ---
        if (mainCaseId != null) {
            try { insert new Agent__c(Case__c = mainCaseId); } catch(Exception e) {}

            try {
                String validType = 'Inbound Call';
                List<Schema.PicklistEntry> pEntries = Case_Action__c.Type__c.getDescribe().getPicklistValues();
                if(!pEntries.isEmpty()) validType = pEntries[0].getValue();

                insert new Case_Action__c(Case__c = mainCaseId, Action__c = 'Callback', Type__c = validType);
                insert new Case_Action__c(Case__c = mainCaseId, Internal_Case__c = mainCaseId, Action__c = 'Callback', Type__c = validType);
            } catch (Exception e) { System.debug('🛑 CASE ACTIONS FAILED: ' + e.getMessage()); }

            try { insert new Knowledge_Article_Tracking__c(Case__c = mainCaseId); } catch(Exception e){}
            try { insert new EmailMessage(ParentId = mainCaseId, Subject = 'Case Email', FromAddress='t@t.com', ToAddress='t@t.com'); } catch(Exception e){}

            // --- 7. OMBUDSMAN ---
            try {
                Integer randomNum = Math.round(Math.random() * 899999) + 100000;
                String uniqueRef = 'AB' + String.valueOf(randomNum) + '-23';

                Ombudsman_Case__c ombCase = new Ombudsman_Case__c(Case__c = mainCaseId, Name = uniqueRef);
                insert ombCase;
                
                // 📎 ATTACH FILE TO OMBUDSMAN (Optimized Method)
                createFile(ombCase.Id, 'Ombudsman Report ' + uniqueRef);

                insert new Ombudsman_Resolution__c(
                    Ombudsman_Case__c = ombCase.Id, 
                    Resolution_Case__c = mainCaseId, 
                    Ombudsman_Remedy__c = 'abc'
                );
                System.debug('✅ Ombudsman Hierarchy Created');
            } catch(Exception e) {
                System.debug('🛑 OMBUDSMAN FAILED: ' + e.getMessage());
            }
        }
    }

    // --- 📎 IMPROVED FILE CREATOR ---
    // Uses FirstPublishLocationId to link immediately (1 Insert, 0 Queries)
    private void createFile(Id parentId, String title) {
        try {
            ContentVersion cv = new ContentVersion();
            cv.Title = title;
            cv.PathOnClient = title.replaceAll(' ', '_') + '.txt';
            cv.VersionData = Blob.valueOf('This is dummy content for ' + title);
            cv.IsMajorVersion = true;
            // The Magic Field: Automatically creates ContentDocumentLink
            cv.FirstPublishLocationId = parentId; 
            insert cv;
        } catch (Exception e) {
            System.debug('⚠️ File Creation Failed for ' + parentId + ': ' + e.getMessage());
        }
    }
}