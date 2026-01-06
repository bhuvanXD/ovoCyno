public class ServiceAccountDataFactory implements Database.Batchable<Integer>, Database.Stateful {
    
    private Integer totalHierarchiesToCreate;
    private Integer successfulCreations = 0;
    
    // Constructor: Pass the number of full hierarchies you want to create
    public ServiceAccountDataFactory(Integer count) {
        this.totalHierarchiesToCreate = count;
    }

    // 1. START: Generates "tickets" (1 to N) to process
    public Iterable<Integer> start(Database.BatchableContext bc) {
        List<Integer> scope = new List<Integer>();
        for (Integer i = 1; i <= totalHierarchiesToCreate; i++) {
            scope.add(i);
        }
        return scope;
    }

    // 2. EXECUTE: Creates one hierarchy per "ticket" in the scope
    public void execute(Database.BatchableContext bc, List<Integer> scope) {
        for (Integer i : scope) {
            createSingleHierarchy(i); 
        }
    }

    // 3. FINISH
    public void finish(Database.BatchableContext bc) {
        System.debug('✅ BATCH COMPLETE.');
        System.debug('Total Hierarchies Created: ' + successfulCreations);
        System.debug('Total Records Generated (approx): ' + (successfulCreations * 26));
    }

    // --- HELPER: CREATES 1 FULL HIERARCHY ---
    private void createSingleHierarchy(Integer index) {
        try {
            // A. Create Dummy Parents (Account & Contact)
            Account parentAccount = new Account(Name = 'Bulk Account ' + System.currentTimeMillis() + '_' + index);
            insert parentAccount;

            Contact customerContact = new Contact(
                AccountId = parentAccount.Id,
                LastName = 'Bulk Contact ' + index,
                Email = 'test' + index + '@example.com'
            );
            insert customerContact;

            // B. Create SERVICE ACCOUNT (Using your specific fields)
            Service_Account__c sa = new Service_Account__c(
                Offset__c = '0',
                Name = 'SA_INTERNAL_MIGRATION_' + index,       // Unique Name
                Service_Account_Id__c = 'ACC-100000' + index,   // Unique ID
                Billing_Information_Offset__c = '0',
                SSE_Migration_Status_Offset__c = '0'
            );
            insert sa;
            Id saId = sa.Id;

            // C. Create MAIN CASE (Using your specific fields)
            Case c = new Case(
                Service_Account__c = sa.Id,
                Complaints_Severity__c = '2',
                Issue__c = 'What is the customer’s complaint about?',
                Investigation__c = 'What is the outcome the customer is looking for?',
                Resolution__c = 'What steps have you taken to resolve this?',
                Outcome__c = 'Describe the reason you are escalating',
                Origin = 'CSAT',
                Triage_Filter__c = 'PAYM',
                Category_Level_Two__c = 'Collections',
                Category_Level_Three__c = 'Payment Plans',
                Signposted__c = false,
                Subject = 'Bulk Generated Case ' + index
            );
            insert c;
            Id mainCaseId = c.Id;

            // --- D. CREATE ALL CHILDREN ---
            
            // 1. Service Account Children
            List<SObject> saChildren = new List<SObject>{
                new Addon__c(Service_Account__c = saId),
                new Communication__c(Service_Account__c = saId),
                new Contact_Permission__c(Service_Account__c = saId, Account_Binding_Key__c = 'KEY-' + index + '-' + System.currentTimeMillis()),
                new SSE_Migration_Flags__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId),
                new SSE_Migration_Reference__c(Service_Account__c = saId, SSE_Service_Account_Id__c = saId),
                new Gas_Card__c(
                    Service_Account__c = saId, 
                    Customer__c = customerContact.Id, 
                    Address_Line_1__c = '123 Bulk St', 
                    Town_City__c = 'Bulk City', 
                    Postcode__c = 'BK1 9ZZ'
                )
            };
            insert saChildren;

            // 2. Agents & Emails
            Agent__c saAgent = new Agent__c(Service_Account__c = saId);
            insert saAgent;
            insert new EmailMessage(RelatedToId = saAgent.Id, Subject = 'Agent Email', FromAddress='t@t.com', ToAddress='t@t.com');

            Agent_Action__c agentAction = new Agent_Action__c(Agent__c = saAgent.Id);
            insert agentAction;
            insert new EmailMessage(RelatedToId = agentAction.Id, Subject = 'Action Email', FromAddress='t@t.com', ToAddress='t@t.com');

            // 3. Financials
            Direct_Debit_Mandate__c ddm = new Direct_Debit_Mandate__c(Service_Account__c = saId, Mandate_ID__c = 'DD-' + index + '-' + System.currentTimeMillis());
            insert ddm;
            insert new Direct_Debit_Subscription__c(Service_Account__c = saId, Direct_Debit_Mandate__c = ddm.Id, Subscription_ID__c = 'SUB-' + index);

            // 4. Supply Points
            Supply_Point__c sp = new Supply_Point__c(Name = 'Bulk SP ' + index);
            insert sp;
            insert new Supply_Point_Ownership__c(Service_Account__c = saId, Supply_Point__c = sp.Id);
            insert new Dispute__c(Supply_Point__c = sp.Id, Dispute_Id__c = 'DIS-' + index);
            insert new Gas_Card__c(Service_Account__c = saId, Meter_Point_Reference__c = sp.Id, Town_City__c = 'SP City', Postcode__c = 'SP1 1AA');

            // 5. Case Related Items
            insert new Agent__c(Case__c = mainCaseId);
            
            // Get valid picklist value for Action Type
            String validType = 'Inbound Call'; // Default
            List<Schema.PicklistEntry> pEntries = Case_Action__c.Type__c.getDescribe().getPicklistValues();
            if(!pEntries.isEmpty()) validType = pEntries[0].getValue();

            insert new Case_Action__c(Case__c = mainCaseId, Action__c = 'Callback', Type__c = validType);
            
            // Wrap optional inserts in try/catch to avoid strict validation failures stopping the whole row
            try { insert new Case_Action__c(Internal_Case__c = mainCaseId, Action__c = 'Callback', Type__c = validType); } catch(Exception e){}
            try { insert new EmailMessage(ParentId = mainCaseId, Subject = 'Case Email', FromAddress='t@t.com', ToAddress='t@t.com'); } catch(Exception e){}
            try { insert new Knowledge_Article_Tracking__c(Case__c = mainCaseId); } catch(Exception e){}

            // 6. Ombudsman Hierarchy (With Random Unique Name)
            Integer randomNum = Math.round(Math.random() * 899999) + 100000;
            String uniqueRef = 'AB' + String.valueOf(randomNum) + '-99';

            try {
                Ombudsman_Case__c ombCase = new Ombudsman_Case__c(Case__c = mainCaseId, Name = uniqueRef);
                insert ombCase;
                insert new Ombudsman_Resolution__c(Ombudsman_Case__c = ombCase.Id, Resolution_Case__c = mainCaseId, Ombudsman_Remedy__c = 'abc');
            } catch(Exception e) {
                System.debug('Ombudsman creation skipped for index ' + index + ': ' + e.getMessage());
            }

            successfulCreations++;

        } catch (Exception e) {
            System.debug('🛑 Error creating hierarchy index ' + index + ': ' + e.getMessage());
        }
    }
}